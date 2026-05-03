#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${ROOT_DIR}/.build-payload"
PAYLOAD_DIR="${TEMP_DIR}/payload"
PAYLOAD_FILE="${TEMP_DIR}/payload.tar.gz"
DIST_DIR="${ROOT_DIR}/dist"
IMAGES_DIR="${ROOT_DIR}/images"
IMAGE_JSON="${IMAGES_DIR}/image.json"
INSTALLER_TEMPLATE="${ROOT_DIR}/install.sh"
INSTALLER_BASENAME="clickhouse-operator-installer"
CHART_SRC_DIR="${ROOT_DIR}/charts/clickhouse-operator"

ARCH="amd64"
PLATFORM="linux/amd64"
BUILD_ALL="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--arch amd64|arm64|all]

Examples:
  ./build.sh --arch amd64
  ./build.sh --arch arm64
  ./build.sh --arch all
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64)
      ARCH="amd64"
      PLATFORM="linux/amd64"
      BUILD_ALL="false"
      ;;
    arm64|arm|aarch64)
      ARCH="arm64"
      PLATFORM="linux/arm64"
      BUILD_ALL="false"
      ;;
    all)
      BUILD_ALL="true"
      ;;
    *)
      die "Unsupported arch: $1"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch|-a)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        normalize_arch "$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

python_cmd() {
  if command -v python >/dev/null 2>&1; then
    printf 'python'
  else
    printf 'python3'
  fi
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
  command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || die "python or python3 is required"
  [[ -f "${INSTALLER_TEMPLATE}" ]] || die "install.sh is missing"
  [[ -f "${IMAGE_JSON}" ]] || die "images/image.json is missing"
  [[ -d "${CHART_SRC_DIR}" ]] || die "charts/clickhouse-operator is missing"
  grep -q '^__PAYLOAD_BELOW__$' "${INSTALLER_TEMPLATE}" || die "install.sh is missing __PAYLOAD_BELOW__ marker"
}

cleanup() {
  rm -rf "${TEMP_DIR}"
}

trap cleanup EXIT

prepare_directories() {
  rm -rf "${TEMP_DIR}"
  mkdir -p "${PAYLOAD_DIR}/charts" "${PAYLOAD_DIR}/images" "${DIST_DIR}"
}

write_image_metadata() {
  local arch="$1"
  local output_json="$2"
  local output_index="$3"

  "$(python_cmd)" - "${IMAGE_JSON}" "${arch}" "${output_json}" "${output_index}" <<'PY'
import json
import sys

source_path, arch, output_json, output_index = sys.argv[1:]

with open(source_path, "r", encoding="utf-8") as fh:
    items = json.load(fh)

selected = [dict(item) for item in items if item.get("arch") == arch]
if not selected:
    raise SystemExit(f"no image definition found for arch={arch}")

with open(output_json, "w", encoding="utf-8") as fh:
    json.dump(selected, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

with open(output_index, "w", encoding="utf-8", newline="") as fh:
    for item in selected:
        default_target_ref = item.get("tag") or item.get("pull") or ""
        fh.write("\t".join([
            item.get("tar", ""),
            default_target_ref,
            default_target_ref,
            item.get("platform", ""),
            item.get("pull", ""),
        ]) + "\n")
PY
}

prepare_images() {
  local count=0
  local payload_image_json="${PAYLOAD_DIR}/images/image.json"
  local payload_image_index="${PAYLOAD_DIR}/images/image-index.tsv"

  write_image_metadata "${ARCH}" "${payload_image_json}" "${payload_image_index}"

  while IFS=$'\t' read -r tar_name load_ref default_target_ref platform pull; do
    [[ -n "${tar_name}" ]] || continue
    [[ -n "${platform}" ]] || platform="${PLATFORM}"

    log "Pull ${pull} (${platform})"
    docker pull --platform "${platform}" "${pull}"

    if [[ "${pull}" != "${default_target_ref}" ]]; then
      log "Tag ${pull} -> ${default_target_ref}"
      docker tag "${pull}" "${default_target_ref}"
    fi

    log "Save ${default_target_ref} -> ${PAYLOAD_DIR}/images/${tar_name}"
    docker save -o "${PAYLOAD_DIR}/images/${tar_name}" "${default_target_ref}"
    count=$((count + 1))
  done < "${payload_image_index}"

  (( count > 0 )) || die "No image definition found for arch=${ARCH}"
  success "Prepared ${count} image(s) for arch=${ARCH}"
}

package_payload() {
  local installer_path="${DIST_DIR}/${INSTALLER_BASENAME}-${ARCH}.run"

  log "Copying chart payload"
  cp -R "${CHART_SRC_DIR}" "${PAYLOAD_DIR}/charts/"

  log "Creating payload archive"
  tar -C "${PAYLOAD_DIR}" -czf "${PAYLOAD_FILE}" .
  tar -tzf "${PAYLOAD_FILE}" >/dev/null

  log "Assembling installer ${installer_path}"
  cat "${INSTALLER_TEMPLATE}" "${PAYLOAD_FILE}" > "${installer_path}"
  chmod +x "${installer_path}"
  sha256sum "${installer_path}" > "${installer_path}.sha256"
  success "Generated $(basename "${installer_path}")"
}

show_result() {
  local installer_path="${DIST_DIR}/${INSTALLER_BASENAME}-${ARCH}.run"
  echo
  success "Build complete for ${ARCH}"
  echo "Installer: ${installer_path}"
  echo "Checksum : ${installer_path}.sha256"
}

build_one() {
  normalize_arch "$1"
  prepare_directories
  prepare_images
  package_payload
  show_result
}

main() {
  parse_args "$@"
  check_requirements

  if [[ "${BUILD_ALL}" == "true" ]]; then
    build_one amd64
    build_one arm64
  else
    build_one "${ARCH}"
  fi
}

main "$@"
