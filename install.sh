#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="clickhouse-operator"
INSTALLER_VERSION="0.2.0"
UPSTREAM_CHART_VERSION="0.26.3"
WORKDIR="/tmp/${APP_NAME}-installer"
CHART_DIR="${WORKDIR}/charts/clickhouse-operator"
IMAGE_DIR="${WORKDIR}/images"
IMAGE_INDEX="${IMAGE_DIR}/image-index.tsv"
VALUES_FILE="${WORKDIR}/values-install.yaml"

ACTION="install"
DEPLOYMENT_PROFILE="production"
RELEASE_NAME="clickhouse-operator"
NAMESPACE="clickhouse"
WAIT_TIMEOUT="15m"
IMAGE_PULL_POLICY="IfNotPresent"
REGISTRY_REPO="sealos.hub:5000/kube4"
REGISTRY_USER="admin"
REGISTRY_PASS="passw0rd"
SKIP_IMAGE_PREPARE="false"
DELETE_CRDS="false"
AUTO_YES="false"
CRD_HOOK_ENABLED="true"
METRICS_EXPORTER_ENABLED="true"
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

CLUSTER_RESOURCE_NAME=""
CLICKHOUSE_CLUSTER_NAME="default"
CLICKHOUSE_SHARDS="1"
CLICKHOUSE_REPLICAS=""
CLICKHOUSE_DATA_SIZE="200Gi"
CLICKHOUSE_LOG_SIZE="20Gi"
CLICKHOUSE_STORAGE_CLASS=""
CLICKHOUSE_SERVICE_TYPE="ClusterIP"
CLICKHOUSE_ADMIN_USER="admin"
CLICKHOUSE_ADMIN_PASSWORD="ClickHouse@123"

KEEPER_RESOURCE_NAME=""
KEEPER_REPLICAS="3"
KEEPER_DATA_SIZE="20Gi"

CLICKHOUSE_CPU_REQUEST="2"
CLICKHOUSE_CPU_LIMIT="4"
CLICKHOUSE_MEMORY_REQUEST="4Gi"
CLICKHOUSE_MEMORY_LIMIT="8Gi"
KEEPER_CPU_REQUEST="500m"
KEEPER_CPU_LIMIT="1"
KEEPER_MEMORY_REQUEST="1Gi"
KEEPER_MEMORY_LIMIT="2Gi"

CLICKHOUSE_HTTP_PORT="8123"
CLICKHOUSE_TCP_PORT="9000"
CLICKHOUSE_INTERSERVER_PORT="9009"
CLICKHOUSE_METRICS_PORT="9363"
KEEPER_CLIENT_PORT="2181"
KEEPER_METRICS_PORT="7000"

HELM_VALUES_FILES=()
HELM_SET_ARGS=()
HELM_EXTRA_ARGS=()
PAYLOAD_OFFSET=""
OPERATOR_IMAGE=""
METRICS_EXPORTER_IMAGE=""
CRD_KUBECTL_IMAGE=""
CLICKHOUSE_SERVER_IMAGE=""
CLICKHOUSE_KEEPER_IMAGE=""

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
  echo -e "${BOLD}ClickHouse Offline Installer${NC}"
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
  install       Install or reconcile clickhouse-operator and optional cluster resources
  uninstall     Uninstall the Helm release and optionally delete CRDs
  status        Show Helm, operator, CHI and CHK status
  help          Show this message

Core options:
  -n, --namespace <ns>                 Namespace, default: ${NAMESPACE}
  --release-name <name>               Helm release name, default: ${RELEASE_NAME}
  --wait-timeout <duration>           Helm wait timeout, default: ${WAIT_TIMEOUT}
  --profile <production|single|operator-only>
                                       Default: ${DEPLOYMENT_PROFILE}

Image and registry:
  --registry <repo-prefix>            Target image repo prefix, default: ${REGISTRY_REPO}
  --registry-user <user>              Registry username, default: ${REGISTRY_USER}
  --registry-password <pass>          Registry password, default: <hidden>
  --image-pull-policy <policy>        Always|IfNotPresent|Never, default: ${IMAGE_PULL_POLICY}
  --skip-image-prepare                Reuse images already present in the target registry

Operator behavior:
  --disable-crd-hook                  Disable the Helm hook job that applies CRDs
  --disable-metrics-exporter          Disable the operator metrics-exporter sidecar
  --enable-service-monitor            Create operator ServiceMonitor and cluster PodMonitor resources
  --enable-dashboards                 Create Grafana dashboard config from the vendored chart
  --dashboard-folder <name>           Grafana folder annotation, default: ${DASHBOARD_FOLDER}
  --stack-label-value <value>         Override ${STACK_LABEL_KEY}, default: ${STACK_LABEL_VALUE}
  --namespace-scoped-rbac             Use namespace scoped RBAC instead of cluster scoped RBAC
  --operator-username <name>          Operator secret username, default: ${OPERATOR_SECRET_USERNAME}
  --operator-password <pass>          Operator secret password, default: ${OPERATOR_SECRET_PASSWORD}

Cluster behavior:
  --cluster-name <name>               CHI resource name, default: <release-name>-cluster
  --shards <n>                        ClickHouse shards, default: 1
  --replicas <n>                      ClickHouse replicas, default: 2 in production, 1 in single
  --data-size <size>                  ClickHouse data PVC size, default: ${CLICKHOUSE_DATA_SIZE}
  --log-size <size>                   ClickHouse log PVC size, default: ${CLICKHOUSE_LOG_SIZE}
  --storage-class <name>              StorageClass for ClickHouse and Keeper PVCs
  --service-type <type>               ClusterIP|NodePort|LoadBalancer, default: ${CLICKHOUSE_SERVICE_TYPE}
  --admin-user <name>                 ClickHouse admin user, default: ${CLICKHOUSE_ADMIN_USER}
  --admin-password <pass>             ClickHouse admin password, default: ${CLICKHOUSE_ADMIN_PASSWORD}

Keeper behavior:
  --keeper-name <name>                CHK resource name, default: <release-name>-keeper
  --keeper-replicas <n>               Keeper replicas in production profile, default: ${KEEPER_REPLICAS}
  --keeper-data-size <size>           Keeper PVC size, default: ${KEEPER_DATA_SIZE}

Helm pass-through:
  --helm-values <file>                Additional values file, repeatable
  --helm-set <expr>                   Additional Helm --set item, repeatable
  --helm-arg <arg>                    Additional raw Helm argument, repeatable
  --                                 Append remaining arguments to Helm

Cleanup:
  --delete-crds                       With uninstall, also delete ClickHouse CRDs

Other:
  -y, --yes                           Skip confirmation
  -h, --help                          Show help

Examples:
  ${cmd} install -y
  ${cmd} install --profile single --storage-class nfs --data-size 100Gi -y
  ${cmd} install --enable-service-monitor --enable-dashboards -y
  ${cmd} install --registry harbor.example.com/kube4 --skip-image-prepare -y
  ${cmd} install --profile operator-only -y
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
      --profile)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        DEPLOYMENT_PROFILE="$2"
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
        METRICS_EXPORTER_ENABLED="false"
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
      --cluster-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLUSTER_RESOURCE_NAME="$2"
        shift 2
        ;;
      --shards)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_SHARDS="$2"
        shift 2
        ;;
      --replicas)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_REPLICAS="$2"
        shift 2
        ;;
      --data-size)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_DATA_SIZE="$2"
        shift 2
        ;;
      --log-size)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_LOG_SIZE="$2"
        shift 2
        ;;
      --storage-class)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_STORAGE_CLASS="$2"
        shift 2
        ;;
      --service-type)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_SERVICE_TYPE="$2"
        shift 2
        ;;
      --admin-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_ADMIN_USER="$2"
        shift 2
        ;;
      --admin-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CLICKHOUSE_ADMIN_PASSWORD="$2"
        shift 2
        ;;
      --keeper-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        KEEPER_RESOURCE_NAME="$2"
        shift 2
        ;;
      --keeper-replicas)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        KEEPER_REPLICAS="$2"
        shift 2
        ;;
      --keeper-data-size)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        KEEPER_DATA_SIZE="$2"
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

finalize_defaults() {
  if [[ -z "${CLUSTER_RESOURCE_NAME}" ]]; then
    CLUSTER_RESOURCE_NAME="${RELEASE_NAME}-cluster"
  fi

  if [[ -z "${KEEPER_RESOURCE_NAME}" ]]; then
    KEEPER_RESOURCE_NAME="${RELEASE_NAME}-keeper"
  fi

  if [[ -z "${CLICKHOUSE_REPLICAS}" ]]; then
    case "${DEPLOYMENT_PROFILE}" in
      production)
        CLICKHOUSE_REPLICAS="2"
        ;;
      *)
        CLICKHOUSE_REPLICAS="1"
        ;;
    esac
  fi
}

validate_inputs() {
  [[ -n "${NAMESPACE}" ]] || die "--namespace must not be empty"
  [[ -n "${RELEASE_NAME}" ]] || die "--release-name must not be empty"
  [[ -n "${REGISTRY_REPO}" ]] || die "--registry must not be empty"
  [[ -n "${CLICKHOUSE_ADMIN_USER}" ]] || die "--admin-user must not be empty"
  [[ -n "${CLICKHOUSE_ADMIN_PASSWORD}" ]] || die "--admin-password must not be empty"

  case "${DEPLOYMENT_PROFILE}" in
    production|single|operator-only)
      ;;
    *)
      die "--profile must be one of production, single, operator-only"
      ;;
  esac

  case "${IMAGE_PULL_POLICY}" in
    Always|IfNotPresent|Never)
      ;;
    *)
      die "--image-pull-policy must be one of Always, IfNotPresent, Never"
      ;;
  esac

  case "${CLICKHOUSE_SERVICE_TYPE}" in
    ClusterIP|NodePort|LoadBalancer)
      ;;
    *)
      die "--service-type must be one of ClusterIP, NodePort, LoadBalancer"
      ;;
  esac

  [[ "${CLICKHOUSE_SHARDS}" =~ ^[0-9]+$ ]] || die "--shards must be an integer"
  [[ "${CLICKHOUSE_REPLICAS}" =~ ^[0-9]+$ ]] || die "--replicas must be an integer"
  [[ "${KEEPER_REPLICAS}" =~ ^[0-9]+$ ]] || die "--keeper-replicas must be an integer"

  (( CLICKHOUSE_SHARDS >= 1 )) || die "--shards must be >= 1"
  (( CLICKHOUSE_REPLICAS >= 1 )) || die "--replicas must be >= 1"
  (( KEEPER_REPLICAS >= 1 )) || die "--keeper-replicas must be >= 1"

  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    (( CLICKHOUSE_REPLICAS >= 2 )) || die "production profile requires --replicas >= 2"
    (( KEEPER_REPLICAS >= 3 )) || die "production profile requires --keeper-replicas >= 3"
    (( KEEPER_REPLICAS % 2 == 1 )) || die "production profile requires an odd keeper replica count"
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
  echo "Action                   : ${ACTION}"
  echo "Namespace                : ${NAMESPACE}"
  echo "Release name             : ${RELEASE_NAME}"

  if [[ "${ACTION}" == "install" ]]; then
    echo "Profile                  : ${DEPLOYMENT_PROFILE}"
    echo "Registry                 : ${REGISTRY_REPO}"
    echo "Skip image prepare       : ${SKIP_IMAGE_PREPARE}"
    echo "Image pull policy        : ${IMAGE_PULL_POLICY}"
    echo "CRD hook enabled         : ${CRD_HOOK_ENABLED}"
    echo "Metrics exporter         : ${METRICS_EXPORTER_ENABLED}"
    echo "ServiceMonitor           : ${SERVICE_MONITOR_ENABLED}"
    echo "Dashboards               : ${DASHBOARDS_ENABLED}"
    echo "Namespace scoped RBAC    : ${NAMESPACE_SCOPED_RBAC}"
    if [[ "${DEPLOYMENT_PROFILE}" != "operator-only" ]]; then
      echo "CHI resource             : ${CLUSTER_RESOURCE_NAME}"
      echo "Shards                   : ${CLICKHOUSE_SHARDS}"
      echo "Replicas                 : ${CLICKHOUSE_REPLICAS}"
      echo "Data size                : ${CLICKHOUSE_DATA_SIZE}"
      echo "Log size                 : ${CLICKHOUSE_LOG_SIZE}"
      echo "Storage class            : ${CLICKHOUSE_STORAGE_CLASS:-<cluster-default>}"
      echo "Service type             : ${CLICKHOUSE_SERVICE_TYPE}"
      echo "Admin user               : ${CLICKHOUSE_ADMIN_USER}"
    fi
    if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
      echo "CHK resource             : ${KEEPER_RESOURCE_NAME}"
      echo "Keeper replicas          : ${KEEPER_REPLICAS}"
      echo "Keeper data size         : ${KEEPER_DATA_SIZE}"
    fi
    echo "Wait timeout             : ${WAIT_TIMEOUT}"
  fi

  if [[ "${ACTION}" == "uninstall" ]]; then
    echo "Delete CRDs              : ${DELETE_CRDS}"
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

  if [[ "${DEPLOYMENT_PROFILE}" != "operator-only" ]]; then
    CLICKHOUSE_SERVER_IMAGE="$(find_image_ref_by_name "clickhouse-server")" || die "Unable to resolve clickhouse-server image"
  fi

  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    CLICKHOUSE_KEEPER_IMAGE="$(find_image_ref_by_name "clickhouse-keeper")" || die "Unable to resolve clickhouse-keeper image"
  fi
}

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

storage_class_block() {
  local indent="$1"
  if [[ -n "${CLICKHOUSE_STORAGE_CLASS}" ]]; then
    printf '%*sstorageClassName: "%s"\n' "${indent}" '' "$(yaml_escape "${CLICKHOUSE_STORAGE_CLASS}")"
  fi
}

clickhouse_pod_affinity_block() {
  local indent="$1"
  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    cat <<EOF
$(printf '%*s' "${indent}" '')affinity:
$(printf '%*s' "$((indent + 2))" '')podAntiAffinity:
$(printf '%*s' "$((indent + 4))" '')preferredDuringSchedulingIgnoredDuringExecution:
$(printf '%*s' "$((indent + 6))" '')- weight: 100
$(printf '%*s' "$((indent + 8))" '')podAffinityTerm:
$(printf '%*s' "$((indent + 10))" '')labelSelector:
$(printf '%*s' "$((indent + 12))" '')matchExpressions:
$(printf '%*s' "$((indent + 12))" '')- key: app.kubernetes.io/name
$(printf '%*s' "$((indent + 14))" '')operator: In
$(printf '%*s' "$((indent + 14))" '')values:
$(printf '%*s' "$((indent + 14))" '')- clickhouse
$(printf '%*s' "$((indent + 10))" '')topologyKey: kubernetes.io/hostname
EOF
  fi
}

keeper_pod_affinity_block() {
  local indent="$1"
  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    cat <<EOF
$(printf '%*s' "${indent}" '')affinity:
$(printf '%*s' "$((indent + 2))" '')podAntiAffinity:
$(printf '%*s' "$((indent + 4))" '')preferredDuringSchedulingIgnoredDuringExecution:
$(printf '%*s' "$((indent + 6))" '')- weight: 100
$(printf '%*s' "$((indent + 8))" '')podAffinityTerm:
$(printf '%*s' "$((indent + 10))" '')labelSelector:
$(printf '%*s' "$((indent + 12))" '')matchExpressions:
$(printf '%*s' "$((indent + 12))" '')- key: app.kubernetes.io/name
$(printf '%*s' "$((indent + 14))" '')operator: In
$(printf '%*s' "$((indent + 14))" '')values:
$(printf '%*s' "$((indent + 14))" '')- clickhouse-keeper
$(printf '%*s' "$((indent + 10))" '')topologyKey: kubernetes.io/hostname
EOF
  fi
}

render_clickhouse_secret() {
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $(yaml_escape "${RELEASE_NAME}")-clickhouse-auth
  namespace: $(yaml_escape "${NAMESPACE}")
type: Opaque
stringData:
  admin_password: "$(yaml_escape "${CLICKHOUSE_ADMIN_PASSWORD}")"
EOF
}

render_keeper_installation() {
  cat <<EOF
apiVersion: clickhouse-keeper.altinity.com/v1
kind: ClickHouseKeeperInstallation
metadata:
  name: $(yaml_escape "${KEEPER_RESOURCE_NAME}")
  namespace: $(yaml_escape "${NAMESPACE}")
spec:
  configuration:
    clusters:
      - name: $(yaml_escape "${CLICKHOUSE_CLUSTER_NAME}")
        layout:
          replicasCount: ${KEEPER_REPLICAS}
    settings:
      logger/level: "information"
      logger/console: "true"
      listen_host: "0.0.0.0"
      keeper_server/tcp_port: "${KEEPER_CLIENT_PORT}"
      keeper_server/four_letter_word_white_list: "*"
      prometheus/endpoint: "/metrics"
      prometheus/port: "${KEEPER_METRICS_PORT}"
      prometheus/metrics: "true"
      prometheus/events: "true"
      prometheus/asynchronous_metrics: "true"
      prometheus/status_info: "false"
  defaults:
    templates:
      podTemplate: keeper-pod-template
      volumeClaimTemplate: keeper-data-volume
  templates:
    podTemplates:
      - name: keeper-pod-template
        metadata:
          labels:
            app.kubernetes.io/name: clickhouse-keeper
        spec:
$(keeper_pod_affinity_block 10)
          containers:
            - name: clickhouse-keeper
              image: "$(yaml_escape "${CLICKHOUSE_KEEPER_IMAGE}")"
              imagePullPolicy: ${IMAGE_PULL_POLICY}
              ports:
                - name: client
                  containerPort: ${KEEPER_CLIENT_PORT}
                - name: metrics
                  containerPort: ${KEEPER_METRICS_PORT}
              resources:
                requests:
                  cpu: "$(yaml_escape "${KEEPER_CPU_REQUEST}")"
                  memory: "$(yaml_escape "${KEEPER_MEMORY_REQUEST}")"
                limits:
                  cpu: "$(yaml_escape "${KEEPER_CPU_LIMIT}")"
                  memory: "$(yaml_escape "${KEEPER_MEMORY_LIMIT}")"
          securityContext:
            fsGroup: 101
    volumeClaimTemplates:
      - name: keeper-data-volume
        spec:
          accessModes:
            - ReadWriteOnce
$(storage_class_block 10)
          resources:
            requests:
              storage: "$(yaml_escape "${KEEPER_DATA_SIZE}")"
EOF
}

render_clickhouse_installation() {
  local zookeeper_block=""
  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    zookeeper_block="$(cat <<EOF
    zookeeper:
      nodes:
        - host: keeper-$(yaml_escape "${KEEPER_RESOURCE_NAME}")
          port: ${KEEPER_CLIENT_PORT}
EOF
)"
  fi

  cat <<EOF
apiVersion: clickhouse.altinity.com/v1
kind: ClickHouseInstallation
metadata:
  name: $(yaml_escape "${CLUSTER_RESOURCE_NAME}")
  namespace: $(yaml_escape "${NAMESPACE}")
spec:
  defaults:
    templates:
      podTemplate: clickhouse-pod-template
      serviceTemplate: clickhouse-service-template
      dataVolumeClaimTemplate: clickhouse-data-volume
      logVolumeClaimTemplate: clickhouse-log-volume
  configuration:
${zookeeper_block}
    users:
      $(yaml_escape "${CLICKHOUSE_ADMIN_USER}")/k8s_secret_password: $(yaml_escape "${NAMESPACE}")/$(yaml_escape "${RELEASE_NAME}")-clickhouse-auth/admin_password
      $(yaml_escape "${CLICKHOUSE_ADMIN_USER}")/networks/ip:
        - "::/0"
        - "0.0.0.0/0"
      $(yaml_escape "${CLICKHOUSE_ADMIN_USER}")/profile: "default"
      $(yaml_escape "${CLICKHOUSE_ADMIN_USER}")/quota: "default"
    settings:
      prometheus/endpoint: "/metrics"
      prometheus/port: "${CLICKHOUSE_METRICS_PORT}"
      prometheus/metrics: "true"
      prometheus/events: "true"
      prometheus/asynchronous_metrics: "true"
      prometheus/status_info: "true"
    clusters:
      - name: $(yaml_escape "${CLICKHOUSE_CLUSTER_NAME}")
        layout:
          shardsCount: ${CLICKHOUSE_SHARDS}
          replicasCount: ${CLICKHOUSE_REPLICAS}
  templates:
    serviceTemplates:
      - name: clickhouse-service-template
        generateName: $(yaml_escape "${RELEASE_NAME}")-clickhouse
        spec:
          type: ${CLICKHOUSE_SERVICE_TYPE}
          ports:
            - name: http
              port: ${CLICKHOUSE_HTTP_PORT}
            - name: tcp
              port: ${CLICKHOUSE_TCP_PORT}
    podTemplates:
      - name: clickhouse-pod-template
        metadata:
          labels:
            app.kubernetes.io/name: clickhouse
        spec:
$(clickhouse_pod_affinity_block 10)
          containers:
            - name: clickhouse
              image: "$(yaml_escape "${CLICKHOUSE_SERVER_IMAGE}")"
              imagePullPolicy: ${IMAGE_PULL_POLICY}
              ports:
                - name: http
                  containerPort: ${CLICKHOUSE_HTTP_PORT}
                - name: tcp
                  containerPort: ${CLICKHOUSE_TCP_PORT}
                - name: interserver
                  containerPort: ${CLICKHOUSE_INTERSERVER_PORT}
                - name: metrics
                  containerPort: ${CLICKHOUSE_METRICS_PORT}
              volumeMounts:
                - name: clickhouse-data-volume
                  mountPath: /var/lib/clickhouse
                - name: clickhouse-log-volume
                  mountPath: /var/log/clickhouse-server
              resources:
                requests:
                  cpu: "$(yaml_escape "${CLICKHOUSE_CPU_REQUEST}")"
                  memory: "$(yaml_escape "${CLICKHOUSE_MEMORY_REQUEST}")"
                limits:
                  cpu: "$(yaml_escape "${CLICKHOUSE_CPU_LIMIT}")"
                  memory: "$(yaml_escape "${CLICKHOUSE_MEMORY_LIMIT}")"
          securityContext:
            fsGroup: 101
    volumeClaimTemplates:
      - name: clickhouse-data-volume
        spec:
          accessModes:
            - ReadWriteOnce
$(storage_class_block 10)
          resources:
            requests:
              storage: "$(yaml_escape "${CLICKHOUSE_DATA_SIZE}")"
      - name: clickhouse-log-volume
        spec:
          accessModes:
            - ReadWriteOnce
$(storage_class_block 10)
          resources:
            requests:
              storage: "$(yaml_escape "${CLICKHOUSE_LOG_SIZE}")"
EOF
}

render_clickhouse_pod_monitor() {
  cat <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: $(yaml_escape "${RELEASE_NAME}")-clickhouse-pods
  namespace: $(yaml_escape "${NAMESPACE}")
  labels:
    "$(yaml_escape "${STACK_LABEL_KEY}")": "$(yaml_escape "${STACK_LABEL_VALUE}")"
spec:
  namespaceSelector:
    matchNames:
      - $(yaml_escape "${NAMESPACE}")
  selector:
    matchLabels:
      clickhouse.altinity.com/chi: $(yaml_escape "${CLUSTER_RESOURCE_NAME}")
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
EOF
}

render_keeper_pod_monitor() {
  cat <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: $(yaml_escape "${RELEASE_NAME}")-keeper-pods
  namespace: $(yaml_escape "${NAMESPACE}")
  labels:
    "$(yaml_escape "${STACK_LABEL_KEY}")": "$(yaml_escape "${STACK_LABEL_VALUE}")"
spec:
  namespaceSelector:
    matchNames:
      - $(yaml_escape "${NAMESPACE}")
  selector:
    matchLabels:
      clickhouse-keeper.altinity.com/chk: $(yaml_escape "${KEEPER_RESOURCE_NAME}")
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
EOF
}

write_additional_resources() {
  if [[ "${DEPLOYMENT_PROFILE}" == "operator-only" ]]; then
    echo "additionalResources: []"
    return 0
  fi

  echo "additionalResources:"
  echo "  - |"
  render_clickhouse_secret | sed 's/^/    /'

  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    echo "  - |"
    render_keeper_installation | sed 's/^/    /'
  fi

  echo "  - |"
  render_clickhouse_installation | sed 's/^/    /'

  if [[ "${SERVICE_MONITOR_ENABLED}" == "true" ]]; then
    echo "  - |"
    render_clickhouse_pod_monitor | sed 's/^/    /'

    if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
      echo "  - |"
      render_keeper_pod_monitor | sed 's/^/    /'
    fi
  fi
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
  enabled: ${METRICS_EXPORTER_ENABLED}
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
  username: "$(yaml_escape "${OPERATOR_SECRET_USERNAME}")"
  password: "$(yaml_escape "${OPERATOR_SECRET_PASSWORD}")"
serviceMonitor:
  enabled: ${SERVICE_MONITOR_ENABLED}
  additionalLabels:
    "$(yaml_escape "${STACK_LABEL_KEY}")": "$(yaml_escape "${STACK_LABEL_VALUE}")"
dashboards:
  enabled: ${DASHBOARDS_ENABLED}
  additionalLabels:
    "$(yaml_escape "${DASHBOARD_LABEL_KEY}")": "$(yaml_escape "${DASHBOARD_LABEL_VALUE}")"
    "$(yaml_escape "${STACK_LABEL_KEY}")": "$(yaml_escape "${STACK_LABEL_VALUE}")"
  annotations:
    grafana_folder: "$(yaml_escape "${DASHBOARD_FOLDER}")"
EOF

  write_additional_resources >> "${VALUES_FILE}"
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

  section "Operator Workloads"
  kubectl get deploy,svc -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" 2>/dev/null || warn "No operator resources found"

  section "ClickHouse Resources"
  kubectl get chi -n "${NAMESPACE}" 2>/dev/null || true
  kubectl get chk -n "${NAMESPACE}" 2>/dev/null || true
  kubectl get pods,pvc,svc -n "${NAMESPACE}" 2>/dev/null || true

  if [[ "${SERVICE_MONITOR_ENABLED}" == "true" ]]; then
    section "Monitoring Resources"
    kubectl get servicemonitor,podmonitor -n "${NAMESPACE}" 2>/dev/null || true
  fi

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

  if [[ "${DEPLOYMENT_PROFILE}" != "operator-only" ]]; then
    echo "  kubectl get chi -n ${NAMESPACE}"
    echo "  kubectl describe chi ${CLUSTER_RESOURCE_NAME} -n ${NAMESPACE}"
    echo "  kubectl get svc -n ${NAMESPACE} -l clickhouse.altinity.com/chi=${CLUSTER_RESOURCE_NAME}"
  fi

  if [[ "${DEPLOYMENT_PROFILE}" == "production" ]]; then
    echo "  kubectl get chk -n ${NAMESPACE}"
    echo "  kubectl describe chk ${KEEPER_RESOURCE_NAME} -n ${NAMESPACE}"
  fi
}

main() {
  banner
  parse_action "$@"

  if [[ "${ACTION}" == "help" ]]; then
    usage
    exit 0
  fi

  finalize_defaults
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
