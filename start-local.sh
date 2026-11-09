#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# 1-click deployment of the OpenTelemetry Demo on this machine, with Docker
# Compose or on a local Kubernetes cluster (OrbStack, Docker Desktop, minikube).
#
# Usage: ./start-local.sh [MODE] [OPTIONS]
#
#   Docker Compose modes
#     (none)              full demo with all local backends
#     --grafana-cloud     lean: telemetry to Grafana Cloud, no local backends
#     --vanilla           no backends, noop collector (clean test bed)
#     --no-otel           noop collector, SDKs disabled, backend UIs still run
#     --minimal           the upstream minimal subset
#     --stop              undeploy everything started by the Compose modes
#
#   Kubernetes modes (Helm chart open-telemetry/opentelemetry-demo)
#     --k8s                  full demo with all local backends
#     --k8s-grafana-cloud    chart collector exports to Grafana Cloud
#     --k8s-vanilla          no backends, noop collector
#     --k8s-clean            no backends, no collector at all
#     --k8s-alloy-forward    chart collector forwards to the k8s-monitoring Alloy
#     --k8s-alloy-collector  Alloy (grafana/alloy) replaces the collector
#     --k8s-stop             undeploy everything started by the Kubernetes modes
#
#   Other
#     --status            show what is currently deployed
#     --reset             undeploy everything and delete build/ (keeps .env.local)
#     --help
#
# Options
#     --yes               do not ask for confirmation
#     --no-build          never build the frontend/checkout images locally
#     --skip-credential-check   do not test the Grafana Cloud credentials first
#
# Configuration comes from .env.local (template: .env.example); see
# docs/configuration.md. Re-running a mode upgrades it in place.
# Manual equivalent of every step: docs/deployment-guide.md.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/common.sh"
cd "${REPO_ROOT}"

MODE=""
ASSUME_YES=false
NO_BUILD=false
SKIP_CREDENTIAL_CHECK=false
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=true ;;
    --no-build) NO_BUILD=true ;;
    --skip-credential-check) SKIP_CREDENTIAL_CHECK=true ;;
    --help|-h)  MODE="--help" ;;
    -*)         if [ -z "${MODE}" ]; then MODE="$1"; else die "Unexpected option: $1 (see --help)"; fi ;;
    *)          die "Unexpected argument: $1 (see --help)" ;;
  esac
  shift
done
export ASSUME_YES SKIP_CREDENTIAL_CHECK

CUSTOM_IMAGE_REPO_FRONTEND="workshop/frontend"
CUSTOM_IMAGE_REPO_CHECKOUT="workshop/checkout"
CUSTOM_IMAGE_TAG="local"

# ── Shared preflight ─────────────────────────────────────────────────────────

prepare_config() {
  log_step "Configuration"
  check_env_file
  load_env
  write_resolved_env
  build_compose_env_args
  log_ok "Configuration loaded (.env.local + defaults); resolved values in build/env.resolved"
}

# True when a locally built frontend/checkout image is needed (Faro, Pyroscope).
custom_images_wanted() {
  [ "${NO_BUILD}" = "true" ] && return 1
  ! is_unset "${GRAFANA_FARO_ENDPOINT:-}" || ! is_unset "${GRAFANA_PYROSCOPE_ADDR:-}"
}

# Mode-specific required values. Argument: grafana-cloud | none
require_mode_config() {
  case "$1" in
    grafana-cloud)
      require_vars GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID GRAFANA_CLOUD_APIKEY
      log_info "Testing the Grafana Cloud credentials before deploying..."
      check_grafana_cloud_credentials ;;
  esac
  if is_unset "${GRAFANA_PYROSCOPE_ADDR:-}" && ! is_unset "${GRAFANA_PYROSCOPE_AUTH_USER:-}"; then
    log_warn "GRAFANA_PYROSCOPE_AUTH_USER is set but GRAFANA_PYROSCOPE_ADDR is not; profiling stays off."
  fi
}

# ── Docker Compose ───────────────────────────────────────────────────────────

check_docker() {
  log_step "Preflight: Docker"
  require_cmd docker "https://docs.docker.com/get-docker/ (or OrbStack: brew install orbstack)" || exit 1
  if ! docker info >/dev/null 2>&1; then
    log_error "The Docker daemon is not reachable."
    log_error "  Start Docker Desktop or OrbStack and run this script again."
    log_error "  If both are installed, quit one of them: they compete for the docker socket."
    exit 1
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required: https://docs.docker.com/compose/install/"
  local mem_bytes mem_gb
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  log_ok "Docker is running (engine memory: ~${mem_gb} GB)"
  if [ "${mem_gb}" -lt 8 ]; then
    log_warn "Less than 8 GB is available to Docker; some services may be killed. Raise it in Docker/OrbStack settings."
  fi
}

# Sets COMPOSE_FILES (array of -f arguments) for a mode name.
compose_files_for() {
  COMPOSE_FILES=( -f docker-compose.yml )
  case "$1" in
    full)          ;;
    grafana-cloud) COMPOSE_FILES+=( -f docker-compose.grafana-cloud.yml ) ;;
    vanilla)       COMPOSE_FILES+=( -f docker-compose.vanilla.yml ) ;;
    no-otel)       COMPOSE_FILES+=( -f docker-compose.no-otel.yml ) ;;
    minimal)       COMPOSE_FILES=( -f docker-compose.minimal.yml ) ;;
  esac
}

compose_deployed_count() {
  docker compose "${COMPOSE_ENV_ARGS[@]}" -f docker-compose.yml ps --status running --services 2>/dev/null | wc -l | tr -d ' '
}

compose_up() {
  local mode="$1"
  compose_files_for "${mode}"
  local running
  running="$(compose_deployed_count)"
  if [ "${running}" -gt 0 ]; then
    log_info "${running} service(s) of this project are already running; the stack is recreated in place."
  fi
  if custom_images_wanted && [ "${mode}" != "minimal" ]; then
    log_step "Building the frontend and checkout images (Faro / Pyroscope support)"
    log_info "Upstream images do not contain the Faro and Pyroscope code, so they are built from this repo."
    docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_FILES[@]}" build frontend checkout
  fi
  log_step "Starting services"
  docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_FILES[@]}" up --force-recreate --remove-orphans --detach
}

wait_compose_healthy() {
  local svc="frontend-proxy"
  [ "$1" = "minimal" ] && svc="frontend-proxy"
  log_info "Waiting for ${svc} to be running (timeout: 5 min; the first start pulls images)..."
  local deadline=$(( SECONDS + 300 ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if docker compose "${COMPOSE_ENV_ARGS[@]}" -f docker-compose.yml ps --status running --services 2>/dev/null | grep -q "^${svc}$"; then
      log_ok "${svc} is running"
      return 0
    fi
    sleep 5
  done
  log_warn "${svc} did not reach the running state within 5 minutes."
  log_warn "Check: docker compose logs ${svc}"
  return 1
}

compose_stop() {
  log_step "Stopping the Docker Compose deployment"
  write_resolved_env
  build_compose_env_args
  GRAFANA_OTLP_ENDPOINT="${GRAFANA_OTLP_ENDPOINT:-x}" GRAFANA_INSTANCE_ID="${GRAFANA_INSTANCE_ID:-x}" \
  GRAFANA_CLOUD_APIKEY="${GRAFANA_CLOUD_APIKEY:-x}" \
  docker compose "${COMPOSE_ENV_ARGS[@]}" \
    -f docker-compose.yml -f docker-compose.no-otel.yml \
    --profile local-backends --profile tests --profile odd \
    down --remove-orphans --volumes
  log_ok "Docker Compose deployment removed."
}

print_compose_summary() {
  local mode="$1"
  echo ""
  log_ok "The demo is running (Docker Compose, mode: ${mode})."
  echo ""
  echo "  Shop            http://localhost:8080"
  echo "  Load generator  http://localhost:8080/loadgen/"
  echo "  Feature flags   http://localhost:8080/feature"
  case "${mode}" in
    full|no-otel)
      echo "  Jaeger          http://localhost:8080/jaeger/ui"
      echo "  Grafana         http://localhost:8080/grafana/" ;;
    grafana-cloud)
      echo ""
      echo "  Telemetry is sent to Grafana Cloud; no local backends are running."
      echo "  Verify:  docker compose logs otel-collector | grep -i -E 'error|export'"
      echo "  Then open your Grafana Cloud stack > Explore and query the Tempo / Mimir / Loki data sources." ;;
    vanilla)
      echo ""
      echo "  No backends and no telemetry destination: the noop collector drops everything." ;;
  esac
  echo ""
  echo "  Next:   ./start-local.sh --stop                undeploy"
  echo "          ./start-local.sh --k8s-grafana-cloud   same demo on local Kubernetes"
  echo "          scripts/render-assets.sh               render the SLO / synthetic check / k6 assets"
  echo "  Manual: docs/deployment-guide.md#docker-compose"
  echo ""
}

# ── Kubernetes ───────────────────────────────────────────────────────────────

# Sets K8S_CTX, KUBECTL (array) and HELM (array). Never changes the user's
# current kubectl context: every call carries --context / --kube-context.
detect_k8s_context() {
  require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/ (brew install kubectl)" || exit 1
  require_cmd helm "https://helm.sh/docs/intro/install/ (brew install helm)" || exit 1

  K8S_CTX=""
  if ! is_unset "${K8S_CONTEXT:-}"; then
    kubectl config get-contexts "${K8S_CONTEXT}" >/dev/null 2>&1 || die "K8S_CONTEXT='${K8S_CONTEXT}' does not exist (kubectl config get-contexts)."
    K8S_CTX="${K8S_CONTEXT}"
  else
    local c
    # Only local clusters are auto-selected, so a typo never deploys to a cloud cluster.
    for c in orbstack docker-desktop minikube; do
      if kubectl config get-contexts "${c}" >/dev/null 2>&1; then K8S_CTX="${c}"; break; fi
    done
  fi

  if [ -z "${K8S_CTX}" ]; then
    log_warn "No local Kubernetes context found (looked for: orbstack, docker-desktop, minikube)."
    if command -v minikube >/dev/null 2>&1 && confirm "Start a minikube cluster now (${MINIKUBE_CPUS} CPUs, ${MINIKUBE_MEMORY_MB} MB)?"; then
      minikube start --driver=docker --cpus="${MINIKUBE_CPUS}" --memory="${MINIKUBE_MEMORY_MB}"
      K8S_CTX="minikube"
    else
      log_error "Create a local cluster, then run this script again. Pick one:"
      log_error "  - OrbStack:       OrbStack > Settings > Kubernetes > Enable"
      log_error "  - Docker Desktop: Settings > Kubernetes > Enable Kubernetes > Apply & restart"
      log_error "  - minikube:       minikube start --driver=docker --cpus=${MINIKUBE_CPUS} --memory=${MINIKUBE_MEMORY_MB}"
      log_error "  - or set K8S_CONTEXT in .env.local to an existing context."
      exit 1
    fi
  fi
  KUBECTL=( kubectl --context "${K8S_CTX}" )
  HELM=( helm --kube-context "${K8S_CTX}" )
  "${KUBECTL[@]}" cluster-info >/dev/null 2>&1 || die "Cannot reach the '${K8S_CTX}' cluster. Is it running? (minikube start / enable Kubernetes in your Docker app)"
  log_ok "Kubernetes context: ${K8S_CTX}"
}

k8s_namespace_exists() { "${KUBECTL[@]}" get namespace "${OTEL_DEMO_NAMESPACE}" >/dev/null 2>&1; }
k8s_release_exists()   { "${HELM[@]}" status "$1" --namespace "${OTEL_DEMO_NAMESPACE}" >/dev/null 2>&1; }

k8s_apply_secret() {
  # k8s_apply_secret NAME KEY... : creates/updates a secret from the exported env vars
  local name="$1"; shift
  local f="${BUILD_DIR}/secret-${name}.env" key
  mkdir -p "${BUILD_DIR}"
  ( umask 077; : > "${f}" )
  for key in "$@"; do
    eval "printf '%s=%s\n' \"${key}\" \"\${${key}}\"" >> "${f}"
  done
  "${KUBECTL[@]}" -n "${OTEL_DEMO_NAMESPACE}" create secret generic "${name}" --from-env-file="${f}" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
  rm -f "${f}"
  log_ok "Secret ${name} applied to namespace ${OTEL_DEMO_NAMESPACE}"
}

# Builds the frontend and checkout images and makes them visible to the cluster.
k8s_build_custom_images() {
  log_step "Building the frontend and checkout images (Faro / Pyroscope support)"
  require_cmd docker "https://docs.docker.com/get-docker/" || exit 1
  docker info >/dev/null 2>&1 || die "The Docker daemon is not reachable; it is needed to build the custom images."
  docker build -f src/frontend/Dockerfile -t "${CUSTOM_IMAGE_REPO_FRONTEND}:${CUSTOM_IMAGE_TAG}" .
  docker build -f src/checkout/Dockerfile -t "${CUSTOM_IMAGE_REPO_CHECKOUT}:${CUSTOM_IMAGE_TAG}" .
  case "${K8S_CTX}" in
    minikube)
      minikube image load "${CUSTOM_IMAGE_REPO_FRONTEND}:${CUSTOM_IMAGE_TAG}"
      minikube image load "${CUSTOM_IMAGE_REPO_CHECKOUT}:${CUSTOM_IMAGE_TAG}" ;;
    orbstack|docker-desktop)
      log_ok "${K8S_CTX} shares the Docker image store; no image load needed." ;;
    *)
      log_warn "Context '${K8S_CTX}' cannot see local images. Push them to a registry and set"
      log_warn "components.<name>.imageOverride yourself; continuing with the upstream images."
      return 1 ;;
  esac
}

# Writes build/values-extras.yaml: the pod name needed by selective failure,
# Faro / Pyroscope settings and the custom image overrides. A component key is
# only written when it has content: an empty key is null in Helm and would
# delete that component from the chart.
k8s_write_extras() {
  local use_custom="$1"
  local f="${BUILD_DIR}/values-extras.yaml"
  mkdir -p "${BUILD_DIR}"
  ( umask 077; : > "${f}" )
  {
    echo "# Generated by start-local.sh from .env.local. Do not edit; do not commit."
    echo "components:"
    echo "  product-catalog:"
    echo "    envOverrides:"
    echo "      - name: OTEL_K8S_POD_NAME"
    echo "        valueFrom:"
    echo "          fieldRef:"
    echo "            fieldPath: metadata.name"

    if [ "${use_custom}" = "true" ] || ! is_unset "${GRAFANA_FARO_ENDPOINT:-}"; then
      echo "  frontend:"
      if [ "${use_custom}" = "true" ]; then
        echo "    imageOverride:"
        echo "      repository: ${CUSTOM_IMAGE_REPO_FRONTEND}"
        echo "      tag: ${CUSTOM_IMAGE_TAG}"
        echo "      pullPolicy: IfNotPresent"
      fi
      if ! is_unset "${GRAFANA_FARO_ENDPOINT:-}"; then
        echo "    envOverrides:"
        echo "      - name: GRAFANA_FARO_ENDPOINT"
        echo "        value: \"${GRAFANA_FARO_ENDPOINT}\""
      fi
    fi

    if [ "${use_custom}" = "true" ] || ! is_unset "${GRAFANA_PYROSCOPE_ADDR:-}"; then
      echo "  checkout:"
      if [ "${use_custom}" = "true" ]; then
        echo "    imageOverride:"
        echo "      repository: ${CUSTOM_IMAGE_REPO_CHECKOUT}"
        echo "      tag: ${CUSTOM_IMAGE_TAG}"
        echo "      pullPolicy: IfNotPresent"
      fi
      if ! is_unset "${GRAFANA_PYROSCOPE_ADDR:-}"; then
        echo "    envOverrides:"
        echo "      - name: GRAFANA_PYROSCOPE_ADDR"
        echo "        value: \"${GRAFANA_PYROSCOPE_ADDR}\""
        echo "      - name: GRAFANA_PYROSCOPE_AUTH_USER"
        echo "        value: \"${GRAFANA_PYROSCOPE_AUTH_USER:-}\""
        echo "      - name: GRAFANA_PYROSCOPE_AUTH_PASS"
        echo "        valueFrom:"
        echo "          secretKeyRef:"
        echo "            name: grafana-cloud-pyroscope"
        echo "            key: GRAFANA_PYROSCOPE_AUTH_PASS"
      fi
    fi
  } >> "${f}"
}

k8s_deploy() {
  # k8s_deploy LABEL VALUES_FILE...
  local label="$1"; shift
  local values_args=() v
  for v in "$@"; do values_args+=( -f "$v" ); done

  log_step "Deploying: ${label}"
  "${HELM[@]}" repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
  "${HELM[@]}" repo update open-telemetry >/dev/null
  "${KUBECTL[@]}" create namespace "${OTEL_DEMO_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

  local use_custom=false
  if custom_images_wanted; then
    if k8s_build_custom_images; then use_custom=true; fi
  fi
  if ! is_unset "${GRAFANA_PYROSCOPE_ADDR:-}"; then
    k8s_apply_secret grafana-cloud-pyroscope GRAFANA_PYROSCOPE_AUTH_PASS
  fi
  k8s_write_extras "${use_custom}"

  if k8s_release_exists "${OTEL_DEMO_RELEASE}"; then
    log_info "Release ${OTEL_DEMO_RELEASE} already exists in ${OTEL_DEMO_NAMESPACE}; upgrading in place."
  fi
  "${HELM[@]}" upgrade --install "${OTEL_DEMO_RELEASE}" open-telemetry/opentelemetry-demo \
    --version "${OTEL_DEMO_CHART_VERSION}" \
    --namespace "${OTEL_DEMO_NAMESPACE}" \
    -f kubernetes/values-local.yaml \
    ${values_args[@]+"${values_args[@]}"} \
    -f "${BUILD_DIR}/values-extras.yaml"
}

wait_k8s_healthy() {
  log_info "Waiting for all deployments to be available (timeout: 8 min; the first start pulls images)..."
  if "${KUBECTL[@]}" wait deployment --all --for=condition=available --namespace "${OTEL_DEMO_NAMESPACE}" --timeout=480s >/dev/null; then
    log_ok "All deployments are available"
  else
    log_warn "Not all deployments became available in time."
    log_warn "Check: kubectl --context ${K8S_CTX} get pods -n ${OTEL_DEMO_NAMESPACE}"
    return 1
  fi
}

k8s_stop() {
  log_step "Removing the Kubernetes deployment (${OTEL_DEMO_NAMESPACE})"
  "${HELM[@]}" uninstall otel-collector --namespace "${OTEL_DEMO_NAMESPACE}" >/dev/null 2>&1 && log_ok "Alloy release removed" || true
  if "${HELM[@]}" uninstall "${OTEL_DEMO_RELEASE}" --namespace "${OTEL_DEMO_NAMESPACE}" >/dev/null 2>&1; then
    log_ok "Helm release ${OTEL_DEMO_RELEASE} removed"
  else
    log_warn "Helm release ${OTEL_DEMO_RELEASE} not found (already removed?)"
  fi
  if "${KUBECTL[@]}" delete namespace "${OTEL_DEMO_NAMESPACE}" --timeout=120s >/dev/null 2>&1; then
    log_ok "Namespace ${OTEL_DEMO_NAMESPACE} deleted (this also removes the secrets created by this script)"
  else
    log_warn "Namespace ${OTEL_DEMO_NAMESPACE} not found (already removed?)"
  fi
}

print_k8s_summary() {
  local label="$1" fe_svc
  fe_svc="$("${KUBECTL[@]}" -n "${OTEL_DEMO_NAMESPACE}" get svc -l app.kubernetes.io/component=frontend-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -z "${fe_svc}" ] && fe_svc="frontend-proxy"
  echo ""
  log_ok "The demo is deployed to ${K8S_CTX} (namespace ${OTEL_DEMO_NAMESPACE}, mode: ${label})."
  echo ""
  echo "  Open the shop:"
  echo "    kubectl --context ${K8S_CTX} port-forward -n ${OTEL_DEMO_NAMESPACE} svc/${fe_svc} 8080:8080"
  echo "    then http://localhost:8080   (load generator: /loadgen/, feature flags: /feature)"
  case "${label}" in
    full) echo "    Jaeger / Grafana: port-forward svc/jaeger-query (16686) and svc/grafana (80) in the same namespace" ;;
    grafana-cloud) echo "    Verify: kubectl --context ${K8S_CTX} -n ${OTEL_DEMO_NAMESPACE} logs deploy/otel-collector | grep -i -E 'error|export'" ;;
    clean) echo "    No collector is deployed: export errors in pod logs are expected until you deploy one." ;;
    alloy-collector) echo "    Verify: kubectl --context ${K8S_CTX} -n ${OTEL_DEMO_NAMESPACE} logs deploy/otel-collector --tail=30" ;;
    alloy-forward) echo "    Telemetry goes to ${K8S_MONITORING_RELEASE}-alloy-receiver in ${K8S_MONITORING_NAMESPACE}." ;;
  esac
  echo ""
  echo "  Next:   scripts/grafana-cloud-k8s-monitoring/install.sh   monitor the cluster itself in Grafana Cloud"
  echo "          ./start-local.sh --k8s-stop                       undeploy"
  echo "  Manual: docs/deployment-guide.md#kubernetes"
  echo ""
}

run_k8s_mode() {
  local mode="$1"
  prepare_config
  case "${mode}" in
    grafana-cloud) require_mode_config grafana-cloud ;;
    alloy-collector) require_mode_config grafana-cloud ;;
  esac
  log_step "Preflight: Kubernetes"
  detect_k8s_context
  case "${mode}" in
    full)            k8s_deploy "full" ;;
    vanilla)         k8s_deploy "vanilla" kubernetes/values-vanilla.yaml ;;
    clean)           k8s_deploy "clean" kubernetes/values-clean.yaml ;;
    grafana-cloud)
      "${KUBECTL[@]}" create namespace "${OTEL_DEMO_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
      k8s_apply_secret grafana-cloud-otlp GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID GRAFANA_CLOUD_APIKEY
      k8s_deploy "grafana-cloud" kubernetes/values-grafana-cloud.yaml ;;
    alloy-forward)
      if ! "${HELM[@]}" status "${K8S_MONITORING_RELEASE}" --namespace "${K8S_MONITORING_NAMESPACE}" >/dev/null 2>&1; then
        log_warn "Release ${K8S_MONITORING_RELEASE} is not installed in ${K8S_MONITORING_NAMESPACE}."
        log_warn "Run scripts/grafana-cloud-k8s-monitoring/install.sh first, or the demo will have nowhere to send telemetry."
      fi
      render_template kubernetes/values-alloy-forward.yaml.tmpl "${BUILD_DIR}/values-alloy-forward.yaml" || true
      k8s_deploy "alloy-forward" "${BUILD_DIR}/values-alloy-forward.yaml" ;;
    alloy-collector)
      "${KUBECTL[@]}" create namespace "${OTEL_DEMO_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
      k8s_apply_secret alloy-grafana-cloud-creds GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID GRAFANA_CLOUD_APIKEY
      k8s_deploy "clean + alloy-collector" kubernetes/values-clean.yaml
      "${HELM[@]}" repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
      "${HELM[@]}" repo update grafana >/dev/null
      "${HELM[@]}" upgrade --install otel-collector grafana/alloy --version "${ALLOY_CHART_VERSION}" \
        --namespace "${OTEL_DEMO_NAMESPACE}" -f kubernetes/values-alloy-collector.yaml ;;
  esac
  wait_k8s_healthy || true
  print_k8s_summary "${mode}"
}

# ── Status / reset ───────────────────────────────────────────────────────────

show_status() {
  prepare_config
  log_step "Docker Compose"
  if docker info >/dev/null 2>&1; then
    local n; n="$(compose_deployed_count)"
    if [ "${n}" -gt 0 ]; then log_ok "${n} service(s) running"; else log_info "nothing running"; fi
  else
    log_info "Docker daemon not reachable"
  fi
  log_step "Kubernetes"
  if command -v kubectl >/dev/null 2>&1 && command -v helm >/dev/null 2>&1; then
    detect_k8s_context 2>/dev/null || { log_info "no local cluster reachable"; return 0; }
    if k8s_namespace_exists; then
      "${HELM[@]}" list --namespace "${OTEL_DEMO_NAMESPACE}"
    else
      log_info "namespace ${OTEL_DEMO_NAMESPACE} does not exist"
    fi
  else
    log_info "kubectl/helm not installed"
  fi
}

do_reset() {
  log_step "Reset: undeploy everything and delete build/"
  confirm "This removes the demo from Docker Compose and Kubernetes and deletes ./build. .env.local is kept. Continue?" || { log_info "Cancelled."; exit 0; }
  prepare_config
  if docker info >/dev/null 2>&1; then compose_stop; fi
  if command -v kubectl >/dev/null 2>&1 && command -v helm >/dev/null 2>&1 && detect_k8s_context 2>/dev/null; then
    k8s_stop
  fi
  rm -rf "${BUILD_DIR}"
  log_ok "Reset complete. Start again with any mode, e.g. ./start-local.sh --grafana-cloud"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

run_compose_mode() {
  local mode="$1"
  prepare_config
  [ "${mode}" = "grafana-cloud" ] && require_mode_config grafana-cloud
  check_docker
  compose_up "${mode}"
  wait_compose_healthy "${mode}" || true
  print_compose_summary "${mode}"
}

# Allow `source start-local.sh` (used by the tests) without running a mode.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0; fi

case "${MODE}" in
  "")                    run_compose_mode full ;;
  --grafana-cloud)       run_compose_mode grafana-cloud ;;
  --vanilla)             run_compose_mode vanilla ;;
  --no-otel)             run_compose_mode no-otel ;;
  --minimal)             run_compose_mode minimal ;;
  --stop)                prepare_config; check_docker; compose_stop ;;
  --k8s)                 run_k8s_mode full ;;
  --k8s-grafana-cloud)   run_k8s_mode grafana-cloud ;;
  --k8s-vanilla)         run_k8s_mode vanilla ;;
  --k8s-clean)           run_k8s_mode clean ;;
  --k8s-alloy-forward)   run_k8s_mode alloy-forward ;;
  --k8s-alloy-collector) run_k8s_mode alloy-collector ;;
  --k8s-stop)            prepare_config; detect_k8s_context; k8s_stop ;;
  --status)              show_status ;;
  --reset)               do_reset ;;
  --help)                sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *)                     die "Unknown mode: ${MODE} (see ./start-local.sh --help)" ;;
esac
