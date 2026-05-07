#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# 1-click startup script for the OpenTelemetry Demo on Docker Desktop.
#
# Usage:
#   ./start-local.sh                  Full Docker Compose mode (all 22 services)
#   ./start-local.sh --vanilla        Docker Compose vanilla (app only, no backends)
#   ./start-local.sh --minimal        Docker Compose minimal subset
#   ./start-local.sh --no-otel        Docker Compose with noop OTel Collector
#   ./start-local.sh --stop           Stop and remove all Docker Compose services
#
#   ./start-local.sh --k8s            Local K8s full mode (Docker Desktop or minikube, via Helm)
#   ./start-local.sh --k8s-vanilla    Local K8s vanilla (app only, no backends)
#   ./start-local.sh --k8s-stop       Uninstall Helm release and delete namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-}"

# Set by check_k8s. Either "docker-desktop" or "minikube".
LOCAL_K8S_CONTEXT=""

# ── Colour helpers ────────────────────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${NC}"; }

# ── Pre-flight: Docker ────────────────────────────────────────────────────────

check_docker() {
  if ! docker info &>/dev/null; then
    error "Docker is not running. Start Docker Desktop and try again."
    exit 1
  fi

  if ! docker compose version &>/dev/null; then
    error "docker compose (v2) is required but not found."
    error "Update Docker Desktop or install the Compose plugin: https://docs.docker.com/compose/install/"
    exit 1
  fi

  # Warn if Docker Desktop memory allocation looks low
  local mem_bytes
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  local mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if [ "$mem_gb" -lt 8 ]; then
    warn "Docker Desktop memory: ~${mem_gb} GB (recommended: 8 GB+)."
    warn "Some services may OOM. Increase in Docker Desktop → Settings → Resources."
  fi
}

# ── Pre-flight: Kubernetes ────────────────────────────────────────────────────

check_k8s() {
  if ! kubectl version --client &>/dev/null; then
    error "kubectl not found. Install it: https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi

  if ! helm version &>/dev/null; then
    error "Helm not found. Install it: https://helm.sh/docs/intro/install/"
    exit 1
  fi

  # Auto-detect a local Kubernetes context. Prefer docker-desktop for
  # backward compatibility; fall back to minikube. We deliberately do NOT
  # accept arbitrary remote contexts (EKS/GKE/AKS) here — this script is
  # for local development and we don't want a typo to deploy onto a cloud
  # cluster that happens to be the current context.
  if kubectl config get-contexts docker-desktop &>/dev/null; then
    LOCAL_K8S_CONTEXT="docker-desktop"
  elif kubectl config get-contexts minikube &>/dev/null; then
    LOCAL_K8S_CONTEXT="minikube"
  else
    error "No local Kubernetes context found (looked for: docker-desktop, minikube)."
    error ""
    error "Pick one:"
    error "  • Docker Desktop: enable Kubernetes in Settings → Kubernetes → Enable."
    error "  • minikube:       install (https://minikube.sigs.k8s.io/) and run:"
    error "                      minikube start --cpus=4 --memory=8192"
    exit 1
  fi

  info "Using local Kubernetes context: ${LOCAL_K8S_CONTEXT}"
  kubectl config use-context "$LOCAL_K8S_CONTEXT" >/dev/null

  # Verify the cluster is reachable
  if ! kubectl cluster-info &>/dev/null; then
    error "Cannot reach the '${LOCAL_K8S_CONTEXT}' Kubernetes cluster."
    if [ "$LOCAL_K8S_CONTEXT" = "minikube" ]; then
      error "Start it with: minikube start --cpus=4 --memory=8192"
    else
      error "Make sure Kubernetes is enabled and running in Docker Desktop."
    fi
    exit 1
  fi
}

# ── Docker Compose: start ─────────────────────────────────────────────────────

compose_up() {
  local extra_flags="${1:-}"
  info "Starting services..."
  # shellcheck disable=SC2086
  docker compose $extra_flags up --force-recreate --remove-orphans --detach
}

# ── Docker Compose: health wait ───────────────────────────────────────────────

wait_compose_healthy() {
  info "Waiting for frontend proxy to be ready (timeout: 3 min)..."
  local deadline=$(( SECONDS + 180 ))
  while [ $SECONDS -lt $deadline ]; do
    if docker compose ps --status running --services 2>/dev/null | grep -q "^frontendproxy$"; then
      return 0
    fi
    sleep 5
  done
  warn "Frontend proxy did not reach running state within 3 minutes."
  warn "Check logs: docker compose logs frontendproxy"
  return 1
}

# ── Docker Compose: stop ──────────────────────────────────────────────────────

compose_stop() {
  info "Stopping all services and removing volumes..."
  docker compose \
    -f docker-compose.yml \
    -f docker-compose.no-otel.yml \
    --profile tests --profile odd --profile local-backends \
    down --remove-orphans --volumes
  success "Stopped."
}

# ── Kubernetes: deploy ────────────────────────────────────────────────────────

k8s_deploy() {
  local values_args="$1"
  local label="$2"

  info "Adding / updating opentelemetry Helm repo..."
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
  helm repo update open-telemetry

  info "Creating namespace otel-demo (if not exists)..."
  kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -

  info "Deploying ${label} via Helm (this may take a minute on first run)..."
  # shellcheck disable=SC2086
  helm upgrade --install opentelemetry-demo open-telemetry/opentelemetry-demo \
    --namespace otel-demo \
    $values_args
}

# ── Kubernetes: health wait ───────────────────────────────────────────────────

wait_k8s_healthy() {
  info "Waiting for all deployments to be available (timeout: 5 min)..."
  if kubectl wait deployment \
      --all \
      --for=condition=available \
      --namespace otel-demo \
      --timeout=300s; then
    return 0
  else
    warn "Not all deployments became available within 5 minutes."
    warn "Check pod status: kubectl get pods -n otel-demo"
    return 1
  fi
}

# ── Kubernetes: stop ──────────────────────────────────────────────────────────

k8s_stop() {
  info "Uninstalling Helm release..."
  if helm uninstall opentelemetry-demo --namespace otel-demo 2>/dev/null; then
    success "Helm release removed."
  else
    warn "Helm release not found (may already be removed)."
  fi

  info "Deleting namespace otel-demo..."
  if kubectl delete namespace otel-demo --timeout=60s 2>/dev/null; then
    success "Namespace deleted."
  else
    warn "Namespace not found (may already be removed)."
  fi
}

# ── URL summaries ─────────────────────────────────────────────────────────────

print_compose_urls() {
  local mode="$1"
  echo ""
  success "OpenTelemetry Demo is running."
  echo ""
  echo "  Shop         → http://localhost:8080"
  echo "  Load Gen     → http://localhost:8080/loadgen/"
  if [ "$mode" = "vanilla" ]; then
    echo ""
    echo "  No local backends (Jaeger / Grafana / Prometheus) — clean slate for Alloy."
    echo ""
    echo "  To route telemetry to Alloy:"
    echo "    1. Install and configure Alloy with an OTLP receiver on port 4317."
    echo "    2. In .env, set:"
    echo "         OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4317"
    echo "    3. Re-run: docker compose -f docker-compose.yml -f docker-compose.vanilla.yml up -d"
  else
    echo "  Jaeger       → http://localhost:8080/jaeger/ui"
    echo "  Grafana      → http://localhost:8080/grafana/"
  fi
  echo ""
}

print_k8s_urls() {
  local mode="$1"
  local ctx_label="${LOCAL_K8S_CONTEXT:-local}"

  # Discover frontend-proxy service name dynamically — chart has flipped between
  # camelCase (`frontendproxy`) and kebab-case (`frontend-proxy`) across versions.
  local fe_svc=""
  local candidate
  for candidate in \
      opentelemetry-demo-frontend-proxy \
      opentelemetry-demo-frontendproxy \
      frontend-proxy; do
    if kubectl --context="${LOCAL_K8S_CONTEXT}" -n otel-demo get svc "${candidate}" >/dev/null 2>&1; then
      fe_svc="${candidate}"
      break
    fi
  done
  if [ -z "${fe_svc}" ]; then
    fe_svc="$(kubectl --context="${LOCAL_K8S_CONTEXT}" -n otel-demo get svc \
      -l app.kubernetes.io/component=frontend-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  fi
  if [ -z "${fe_svc}" ]; then
    fe_svc="$(kubectl --context="${LOCAL_K8S_CONTEXT}" -n otel-demo get svc \
      -l app.kubernetes.io/component=frontendproxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  fi
  if [ -z "${fe_svc}" ]; then
    fe_svc="opentelemetry-demo-frontend-proxy"
    warn "Could not auto-detect frontend-proxy service; falling back to '${fe_svc}'."
    warn "Run 'kubectl get svc -n otel-demo' to find the actual name."
  fi

  echo ""
  success "OpenTelemetry Demo deployed to ${ctx_label} Kubernetes (namespace: otel-demo)."
  echo ""
  echo "  Start port-forward to access the demo:"
  echo ""
  echo "    kubectl port-forward -n otel-demo svc/${fe_svc} 8080:8080"
  echo ""
  echo "  Then open:"
  echo "    Shop         → http://localhost:8080"
  echo "    Load Gen     → http://localhost:8080/loadgen/"
  if [ "$mode" = "vanilla" ]; then
    echo ""
    echo "  No local backends (Jaeger / Grafana / Prometheus) — clean slate for Alloy."
    echo ""
    echo "  To wire Alloy once deployed in the cluster:"
    echo "    Edit kubernetes/values-local-vanilla.yaml — update the"
    echo "    opentelemetry-collector.config exporters to forward to your Alloy service,"
    echo "    then run: make local-k8s-vanilla"
  else
    echo "    Jaeger       → http://localhost:16686  (port-forward: svc/opentelemetry-demo-jaeger-query)"
    echo "    Grafana      → http://localhost:3000   (port-forward: svc/opentelemetry-demo-grafana)"
  fi
  echo ""
  echo "  Check pods:  kubectl get pods -n otel-demo"
  echo "  View logs:   kubectl logs -n otel-demo deployment/<service-name>"
  echo ""
}

# ── Mode dispatch ─────────────────────────────────────────────────────────────

case "$MODE" in

  "")
    header "OpenTelemetry Demo — full Docker Compose mode"
    check_docker
    compose_up ""
    wait_compose_healthy
    print_compose_urls "full"
    ;;

  --vanilla)
    header "OpenTelemetry Demo — Docker Compose vanilla mode (no local backends)"
    check_docker
    compose_up "-f docker-compose.yml -f docker-compose.vanilla.yml"
    wait_compose_healthy
    print_compose_urls "vanilla"
    ;;

  --minimal)
    header "OpenTelemetry Demo — Docker Compose minimal mode"
    check_docker
    compose_up "-f docker-compose.minimal.yml"
    wait_compose_healthy
    print_compose_urls "full"
    ;;

  --no-otel)
    header "OpenTelemetry Demo — Docker Compose no-OTel mode"
    check_docker
    compose_up "-f docker-compose.yml -f docker-compose.no-otel.yml"
    wait_compose_healthy
    print_compose_urls "full"
    ;;

  --stop)
    header "Stopping OpenTelemetry Demo (Docker Compose)"
    check_docker
    compose_stop
    ;;

  --k8s)
    header "OpenTelemetry Demo — local K8s full mode"
    check_k8s
    # Docker Desktop hosts its K8s inside Docker, so the Docker daemon must
    # be reachable. Minikube manages its own runtime — skip the docker check.
    [ "$LOCAL_K8S_CONTEXT" = "docker-desktop" ] && check_docker
    k8s_deploy "-f kubernetes/values-local.yaml" "full K8s mode"
    wait_k8s_healthy
    print_k8s_urls "full"
    ;;

  --k8s-vanilla)
    header "OpenTelemetry Demo — local K8s vanilla mode (no local backends)"
    check_k8s
    [ "$LOCAL_K8S_CONTEXT" = "docker-desktop" ] && check_docker
    k8s_deploy "-f kubernetes/values-local.yaml -f kubernetes/values-local-vanilla.yaml" "K8s vanilla mode"
    wait_k8s_healthy
    print_k8s_urls "vanilla"
    ;;

  --k8s-stop)
    header "Stopping OpenTelemetry Demo (Kubernetes)"
    check_k8s
    k8s_stop
    ;;

  --help|-h)
    echo ""
    echo "Usage: $(basename "$0") [MODE]"
    echo ""
    echo "  (no flag)        Docker Compose full mode — all 22 services"
    echo "  --vanilla        Docker Compose vanilla — app only, no backends, clean slate for Alloy"
    echo "  --minimal        Docker Compose minimal subset"
    echo "  --no-otel        Docker Compose with noop OTel Collector (SDKs disabled)"
    echo "  --stop           Stop and remove all Docker Compose services"
    echo ""
    echo "  --k8s            Local K8s full mode (Docker Desktop or minikube, via Helm)"
    echo "  --k8s-vanilla    Local K8s vanilla (app only, no backends)"
    echo "  --k8s-stop       Uninstall Helm release and delete otel-demo namespace"
    echo ""
    ;;

  *)
    error "Unknown mode: $MODE"
    echo "Run '$(basename "$0") --help' for usage."
    exit 1
    ;;

esac
