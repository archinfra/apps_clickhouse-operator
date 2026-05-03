#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="clickhouse-operator"
INSTALLER_VERSION="0.1.0"
UPSTREAM_CHART_VERSION="0.26.3"
WORKDIR="/tmp/${APP_NAME}-installer"
CHART_DIR="${WORKDIR}/charts/clickhouse-operator"
IMAGE_DIR="${WORKDIR}/images"
IMAGE_INDEX="${IMAGE_DIR}/image-index.tsv"
VALUES_FILE="${WORKDIR}/values-install.yaml"

ACTION="install"
RELEASE_NAME="clickhouse-operator"
NAMESPACE="clickhouse"
WAIT_TIMEOUT="10m"
IMAGE_PULL_POLICY="IfNotPresent"
REGISTRY_REPO="sealos.hub:5000/kube4"
REGISTRY_USER="admin"
REGISTRY_PASS="passw0rd"
SKIP_IMAGE_PREPARE="false"
DELETE_CRDS="false"
AUTO_YES="false"
CRD_HOOK_ENABLED="true"
METRICS_ENABLED="true"
SERVICE_MONITOR_ENABLED="false"
DASHBOARDS_ENABLED="false"
NAMESPACE_SCOPED_RBAC="false"
OPERATOR_SECRET_USERNAME="clickhouse_operator"
OPERATOR_SECRET_PASSWORD="clickhouse_operator_password"
STACK_LABEL_KEY="monitoring.archinfra.io/stack"
STACK_LABEL_VALUE="default"
DASHBOARD_LABEL_KEY="grafana_dashboard"
DASHBOARD_LABEL_VALUE="1"
DASHBOARD_FOLDER="clickhouse-operator"

HELM_VALUES_FILES=()
HELM_SET_ARGS=()
HELM_EXTRA_ARGS=()
PAYLOAD_OFFSET=""
OPERATOR_IMAGE=""
METRICS_EXPORTER_IMAGE=""
CRD_KUBECTL_IMAGE=""

readonly CRDS=(
  "clickhouseinstallations.clickhouse.altinity.com"
  "clickhouseinstallationtemplates.clickhouse.altinity.com"
  "clickhouseoperatorconfigurations.clickhouse.altinity.com"
  "clickhousekeeperinstallations.clickhouse-keeper.altinity.com"
)

declare -A IMAGE_LOAD_REFS=()
declare -A IMAGE_DEFAULT_TARGETS=()
declare -A IMAGE_EFFECTIVE_TARGETS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

banner() {
  echo -e "${BOLD}ClickHouse Operator Offline Installer${NC}"
  echo "Installer version : ${INSTALLER_VERSION}"
  echo "Chart version     : ${UPSTREAM_CHART_VERSION}"
}

program_name() {
  basename "$0"
}

usage() {
  local cmd="./$(program_name)"
  cat <<EOF
Usage:
  ${cmd} [install] [options]
  ${cmd} <uninstall|status|help> [options]
  ${cmd} -h|--help

Actions:
  install       Install or reconcile clickhouse-operator
  uninstall     Uninstall clickhouse-operator and optionally delete CRDs
  status        Show Helm, workload and CRD status
  help          Show this message

Core options:
  -n, --namespace <ns>                  Namespace, default: ${NAMESPACE}
  --release-name <name>                Helm release name, default: ${RELEASE_NAME}
  --wait-timeout <duration>            Helm wait timeout, default: ${WAIT_TIMEOUT}

Image and registry:
  --registry <repo-prefix>             Target image repo prefix, default: ${REGISTRY_REPO}
  --registry-user <user>               Registry username, default: ${REGISTRY_USER}
  --registry-password <pass>           Registry password, default: <hidden>
  --image-pull-policy <policy>         Always|IfNotPresent|Never, default: ${IMAGE_PULL_POLICY}
  --skip-image-prepare                 Reuse images already present in the target registry

Operator behavior:
  --disable-crd-hook                   Disable the Helm hook job that applies CRDs
  --disable-metrics-exporter           Disable the metrics-exporter sidecar
  --enable-service-monitor             Create ServiceMonitor with label ${STACK_LABEL_KEY}=${STACK_LABEL_VALUE}
  --enable-dashboards                  Create Grafana dashboard config with label ${DASHBOARD_LABEL_KEY}=${DASHBOARD_LABEL_VALUE}
  --dashboard-folder <name>            Grafana folder annotation, default: ${DASHBOARD_FOLDER}
  --stack-label-value <value>          Override ${STACK_LABEL_KEY}, default: ${STACK_LABEL_VALUE}
  --namespace-scoped-rbac              Use namespace scoped RBAC instead of cluster scoped RBAC
  --operator-username <name>           Operator secret username, default: ${OPERATOR_SECRET_USERNAME}
  --operator-password <pass>           Operator secret password, default: ${OPERATOR_SECRET_PASSWORD}

Helm pass-through:
  --helm-values <file>                 Additional values file, repeatable
  --helm-set <expr>                    Additional Helm --set item, repeatable
  --helm-arg <arg>                     Additional raw Helm argument, repeatable
  --                                  Append remaining arguments to Helm

Cleanup:
  --delete-crds                        With uninstall, also delete ClickHouse Operator CRDs

Other:
  -y, --yes                            Skip confirmation
  -h, --help                           Show help

Examples:
  ${cmd} install -y
  ${cmd} install --enable-service-monitor --enable-dashboards -y
  ${cmd} install --registry harbor.example.com/kube4 --skip-image-prepare -y
  ${cmd} install --helm-set operator.resources.requests.cpu=100m -y
  ${cmd} status
  ${cmd} uninstall --delete-crds -y
EOF
}

parse_action() {
  if [[ $# -eq 0 ]]; then
    ACTION="install"
    return
  fi

  case "$1" in
    install|uninstall|status)
      ACTION="$1"
      shift
      ;;
    help|-h|--help)
      ACTION="help"
      shift
      ;;
  esac

  parse_args "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        NAMESPACE="$2"
        shift 2
        ;;
      --release-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        RELEASE_NAME="$2"
        shift 2
        ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        WAIT_TIMEOUT="$2"
        shift 2
        ;;
      --registry)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_REPO="$2"
        shift 2
        ;;
      --registry-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_USER="$2"
        shift 2
        ;;
      --registry-password|--registry-pass)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_PASS="$2"
        shift 2
        ;;
      --image-pull-policy)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_PULL_POLICY="$2"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --disable-crd-hook)
        CRD_HOOK_ENABLED="false"
        shift
        ;;
      --disable-metrics-exporter)
        METRICS_ENABLED="false"
        shift
        ;;
      --enable-service-monitor)
        SERVICE_MONITOR_ENABLED="true"
        shift
        ;;
      --enable-dashboards)
        DASHBOARDS_ENABLED="true"
        shift
        ;;
      --dashboard-folder)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        DASHBOARD_FOLDER="$2"
        shift 2
        ;;
      --stack-label-value)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        STACK_LABEL_VALUE="$2"
        shift 2
        ;;
      --namespace-scoped-rbac)
        NAMESPACE_SCOPED_RBAC="true"
        shift
        ;;
      --operator-username)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        OPERATOR_SECRET_USERNAME="$2"
        shift 2
        ;;
      --operator-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        OPERATOR_SECRET_PASSWORD="$2"
        shift 2
        ;;
      --helm-values)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        HELM_VALUES_FILES+=("$2")
        shift 2
        ;;
      --helm-set)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        HELM_SET_ARGS+=("$2")
        shift 2
        ;;
      --helm-arg)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        HELM_EXTRA_ARGS+=("$2")
        shift 2
        ;;
      --delete-crds)
        DELETE_CRDS="true"
        shift
        ;;
      -y|--yes)
        AUTO_YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          HELM_EXTRA_ARGS+=("$1")
          shift
        done
        break
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ -n "${NAMESPACE}" ]] || die "--namespace must not be empty"
  [[ -n "${RELEASE_NAME}" ]] || die "--release-name must not be empty"
  [[ -n "${REGISTRY_REPO}" ]] || die "--registry must not be empty"

  case "${IMAGE_PULL_POLICY}" in
    Always|IfNotPresent|Never)
      ;;
    *)
      die "--image-pull-policy must be one of Always, IfNotPresent, Never"
      ;;
  esac

  if [[ "${SERVICE_MONITOR_ENABLED}" == "true" && "${METRICS_ENABLED}" != "true" ]]; then
    die "--enable-service-monitor requires metrics-exporter; remove --disable-metrics-exporter"
  fi
}

check_requirements() {
  case "${ACTION}" in
    install)
      command -v helm >/dev/null 2>&1 || die "helm is required"
      command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
      command -v tar >/dev/null 2>&1 || die "tar is required"
      command -v awk >/dev/null 2>&1 || die "awk is required"
      command -v head >/dev/null 2>&1 || die "head is required"
      command -v tail >/dev/null 2>&1 || die "tail is required"
      command -v dd >/dev/null 2>&1 || die "dd is required"
      command -v od >/dev/null 2>&1 || die "od is required"
      if [[ "${SKIP_IMAGE_PREPARE}" != "true" ]]; then
        command -v docker >/dev/null 2>&1 || die "docker is required when image preparation is enabled"
      fi
      ;;
    uninstall|status)
      command -v helm >/dev/null 2>&1 || die "helm is required"
      command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
      ;;
  esac
}

print_plan() {
  section "Execution Plan"
  echo "Action                 : ${ACTION}"
  echo "Namespace              : ${NAMESPACE}"
  echo "Release name           : ${RELEASE_NAME}"

  if [[ "${ACTION}" == "install" ]]; then
    echo "Registry               : ${REGISTRY_REPO}"
    echo "Skip image prepare     : ${SKIP_IMAGE_PREPARE}"
    echo "Image pull policy      : ${IMAGE_PULL_POLICY}"
    echo "CRD hook enabled       : ${CRD_HOOK_ENABLED}"
    echo "Metrics exporter       : ${METRICS_ENABLED}"
    echo "ServiceMonitor         : ${SERVICE_MONITOR_ENABLED}"
    echo "Dashboards             : ${DASHBOARDS_ENABLED}"
    echo "Namespace scoped RBAC  : ${NAMESPACE_SCOPED_RBAC}"
    echo "Wait timeout           : ${WAIT_TIMEOUT}"
  fi

  if [[ "${ACTION}" == "uninstall" ]]; then
    echo "Delete CRDs            : ${DELETE_CRDS}"
  fi
}

confirm_plan() {
  [[ "${AUTO_YES}" == "true" ]] && return 0
  echo
  read -r -p "Continue? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled"
      ;;
  esac
}

cleanup() {
  rm -rf "${WORKDIR}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

init_payload_offset() {
  if [[ -n "${PAYLOAD_OFFSET}" ]]; then
    return 0
  fi

  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Unable to locate embedded payload"

  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0

  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d)
        skip_bytes=$((skip_bytes + 1))
        ;;
      "")
        die "Invalid payload boundary"
        ;;
      *)
        break
        ;;
    esac
  done

  PAYLOAD_OFFSET="$((payload_offset + skip_bytes))"
}

payload_stream() {
  init_payload_offset
  tail -c +"${PAYLOAD_OFFSET}" "$0"
}

payload_extract_entries() {
  local destination="$1"
  shift
  payload_stream | tar -xzf - -C "${destination}" "$@" >/dev/null
}

extract_payload() {
  log "Extracting embedded payload to ${WORKDIR}"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  if [[ "${SKIP_IMAGE_PREPARE}" == "true" ]]; then
    payload_extract_entries "${WORKDIR}" "./charts" "./images/image-index.tsv"
  else
    payload_stream | tar -xzf - -C "${WORKDIR}" >/dev/null
  fi

  [[ -d "${CHART_DIR}" ]] || die "Payload is missing charts/clickhouse-operator"
  [[ -f "${IMAGE_INDEX}" ]] || die "Payload is missing images/image-index.tsv"
  success "Payload extracted"
}

resolve_target_ref() {
  local default_target_ref="$1"
  local suffix="${default_target_ref#*/kube4/}"
  if [[ "${suffix}" == "${default_target_ref}" ]]; then
    suffix="${default_target_ref##*/}"
  fi
  printf '%s/%s' "${REGISTRY_REPO%/}" "${suffix}"
}

image_name_from_ref() {
  local ref="$1"
  local name_tag="${ref##*/}"
  printf '%s' "${name_tag%%:*}"
}

image_repo_from_ref() {
  printf '%s' "${1%:*}"
}

image_tag_from_ref() {
  printf '%s' "${1##*:}"
}

registry_host_from_repo() {
  if [[ "${REGISTRY_REPO}" == */* ]]; then
    printf '%s' "${REGISTRY_REPO%%/*}"
  else
    printf '%s' "${REGISTRY_REPO}"
  fi
}

load_image_metadata() {
  if (( ${#IMAGE_DEFAULT_TARGETS[@]} > 0 )); then
    return 0
  fi

  while IFS=$'\t' read -r tar_name load_ref default_target_ref _platform _pull; do
    [[ -n "${tar_name}" ]] || continue
    IMAGE_LOAD_REFS["${tar_name}"]="${load_ref}"
    IMAGE_DEFAULT_TARGETS["${tar_name}"]="${default_target_ref}"
    IMAGE_EFFECTIVE_TARGETS["${tar_name}"]="$(resolve_target_ref "${default_target_ref}")"
  done < "${IMAGE_INDEX}"

  (( ${#IMAGE_DEFAULT_TARGETS[@]} > 0 )) || die "No image metadata found in ${IMAGE_INDEX}"
}

find_image_ref_by_name() {
  local wanted_name="$1"
  local tar_name
  for tar_name in "${!IMAGE_EFFECTIVE_TARGETS[@]}"; do
    if [[ "$(image_name_from_ref "${IMAGE_EFFECTIVE_TARGETS[${tar_name}]}")" == "${wanted_name}" ]]; then
      printf '%s' "${IMAGE_EFFECTIVE_TARGETS[${tar_name}]}"
      return 0
    fi
  done
  return 1
}

docker_login() {
  local registry_host
  registry_host="$(registry_host_from_repo)"
  log "Logging into registry ${registry_host}"
  if echo "${REGISTRY_PASS}" | docker login "${registry_host}" -u "${REGISTRY_USER}" --password-stdin >/dev/null 2>&1; then
    success "Registry login succeeded"
  else
    warn "Registry login failed for ${registry_host}; continuing"
  fi
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "true" ]] && {
    log "Skipping image prepare because --skip-image-prepare was requested"
    return 0
  }

  docker_login

  local tar_name load_ref target_ref tar_path
  while IFS=$'\t' read -r tar_name load_ref _default_target_ref _platform _pull; do
    [[ -n "${tar_name}" ]] || continue
    tar_path="${IMAGE_DIR}/${tar_name}"
    [[ -f "${tar_path}" ]] || die "Missing image tar: ${tar_path}"

    target_ref="${IMAGE_EFFECTIVE_TARGETS[${tar_name}]}"

    log "Loading ${tar_name}"
    docker load -i "${tar_path}" >/dev/null

    if [[ "${load_ref}" != "${target_ref}" ]]; then
      log "Tagging ${load_ref} -> ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi

    log "Pushing ${target_ref}"
    docker push "${target_ref}" >/dev/null
  done < "${IMAGE_INDEX}"

  success "Image prepare completed"
}

resolve_required_images() {
  OPERATOR_IMAGE="$(find_image_ref_by_name "clickhouse-operator")" || die "Unable to resolve clickhouse-operator image"
  METRICS_EXPORTER_IMAGE="$(find_image_ref_by_name "metrics-exporter")" || die "Unable to resolve metrics-exporter image"
  CRD_KUBECTL_IMAGE="$(find_image_ref_by_name "kubectl")" || die "Unable to resolve kubectl image"
}

write_values_file() {
  cat > "${VALUES_FILE}" <<EOF
namespaceOverride: "${NAMESPACE}"
fullnameOverride: "${RELEASE_NAME}"
operator:
  image:
    repository: "$(image_repo_from_ref "${OPERATOR_IMAGE}")"
    tag: "$(image_tag_from_ref "${OPERATOR_IMAGE}")"
    pullPolicy: "${IMAGE_PULL_POLICY}"
metrics:
  enabled: ${METRICS_ENABLED}
  image:
    repository: "$(image_repo_from_ref "${METRICS_EXPORTER_IMAGE}")"
    tag: "$(image_tag_from_ref "${METRICS_EXPORTER_IMAGE}")"
    pullPolicy: "${IMAGE_PULL_POLICY}"
crdHook:
  enabled: ${CRD_HOOK_ENABLED}
  image:
    repository: "$(image_repo_from_ref "${CRD_KUBECTL_IMAGE}")"
    tag: "$(image_tag_from_ref "${CRD_KUBECTL_IMAGE}")"
    pullPolicy: "${IMAGE_PULL_POLICY}"
rbac:
  namespaceScoped: ${NAMESPACE_SCOPED_RBAC}
secret:
  create: true
  username: "${OPERATOR_SECRET_USERNAME}"
  password: "${OPERATOR_SECRET_PASSWORD}"
serviceMonitor:
  enabled: ${SERVICE_MONITOR_ENABLED}
  additionalLabels:
    "${STACK_LABEL_KEY}": "${STACK_LABEL_VALUE}"
dashboards:
  enabled: ${DASHBOARDS_ENABLED}
  additionalLabels:
    "${DASHBOARD_LABEL_KEY}": "${DASHBOARD_LABEL_VALUE}"
    "${STACK_LABEL_KEY}": "${STACK_LABEL_VALUE}"
  annotations:
    grafana_folder: "${DASHBOARD_FOLDER}"
EOF
}

preview_command() {
  local arg
  for arg in "$@"; do
    printf '%q ' "${arg}"
  done
  printf '\n'
}

helm_release_args() {
  local -a cmd=(
    helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}"
    -n "${NAMESPACE}"
    --create-namespace
    --wait
    --wait-for-jobs
    --timeout "${WAIT_TIMEOUT}"
    -f "${VALUES_FILE}"
  )
  local file set_item extra_arg
  for file in "${HELM_VALUES_FILES[@]}"; do
    cmd+=(-f "${file}")
  done
  for set_item in "${HELM_SET_ARGS[@]}"; do
    cmd+=(--set "${set_item}")
  done
  for extra_arg in "${HELM_EXTRA_ARGS[@]}"; do
    cmd+=("${extra_arg}")
  done
  printf '%s\n' "${cmd[@]}"
}

install_release() {
  local -a helm_cmd=()
  mapfile -t helm_cmd < <(helm_release_args)

  section "Helm Command Preview"
  preview_command "${helm_cmd[@]}"

  "${helm_cmd[@]}"
  success "Helm release reconciled"
}

uninstall_release() {
  section "Uninstall Helm Release"
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    success "Helm release removed"
  else
    warn "Helm release ${RELEASE_NAME} not found in namespace ${NAMESPACE}"
  fi

  if [[ "${DELETE_CRDS}" == "true" ]]; then
    section "Delete CRDs"
    kubectl delete crd "${CRDS[@]}" --ignore-not-found >/dev/null || true
    success "CRD deletion requested"
  fi
}

show_status() {
  section "Helm Status"
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null || warn "Helm release ${RELEASE_NAME} not found"

  section "Workload Status"
  kubectl get all -n "${NAMESPACE}" 2>/dev/null || warn "Namespace ${NAMESPACE} has no matching resources"

  section "CRD Status"
  local crd
  for crd in "${CRDS[@]}"; do
    kubectl get "crd/${crd}" >/dev/null 2>&1 && echo "present  ${crd}" || echo "missing  ${crd}"
  done
}

show_post_install_info() {
  section "Post Install"
  echo "Namespace: ${NAMESPACE}"
  echo "Release  : ${RELEASE_NAME}"
  echo
  echo "Useful commands:"
  echo "  kubectl get pods -n ${NAMESPACE}"
  echo "  kubectl logs -n ${NAMESPACE} deploy/${RELEASE_NAME}"
  echo "  kubectl get chi -A"
  if [[ "${SERVICE_MONITOR_ENABLED}" == "true" ]]; then
    echo "  kubectl get servicemonitor -n ${NAMESPACE}"
  fi
}

main() {
  banner
  parse_action "$@"

  if [[ "${ACTION}" == "help" ]]; then
    usage
    exit 0
  fi

  validate_inputs
  check_requirements
  print_plan
  confirm_plan

  case "${ACTION}" in
    install)
      extract_payload
      load_image_metadata
      prepare_images
      resolve_required_images
      write_values_file
      install_release
      show_post_install_info
      ;;
    uninstall)
      uninstall_release
      ;;
    status)
      show_status
      ;;
    *)
      die "Unsupported action: ${ACTION}"
      ;;
  esac
}

main "$@"
exit 0

__PAYLOAD_BELOW__
