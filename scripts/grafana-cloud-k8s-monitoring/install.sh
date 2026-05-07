#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs the grafana/k8s-monitoring Helm chart (v4.x) into the currently
# selected kubectl context. Reads the Grafana Cloud Access Policy token from
# a file (default: ~/.grafana-cloud-token) and injects it into the chart via
# --set-string so it never appears in the values file or in shell history.
#
# Prereqs:
#   1. A kubectl context pointing at the target cluster (minikube, EKS, etc.)
#         kubectl config current-context
#   2. A Grafana Cloud Access Policy token saved to a file:
#         read -rs GRAFANA_TOKEN              # paste token + Enter (silent)
#         printf '%s' "$GRAFANA_TOKEN" > ~/.grafana-cloud-token
#         chmod 600 ~/.grafana-cloud-token
#         unset GRAFANA_TOKEN
#      Token must have scopes: metrics:write, logs:write, traces:write,
#                              profiles:write, fleet-management:write
#   3. helm 3 installed
#
# Usage:
#   ./scripts/grafana-cloud-k8s-monitoring/install.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME    Cluster identifier in Grafana Cloud
#                          (default: <kubectl-current-context>)
#   --token-file PATH      Path to file containing the Grafana Cloud token
#                          (default: ~/.grafana-cloud-token)
#   --namespace NAME       Namespace to install into
#                          (default: grafana-k8s-monitoring)
#   --release-name NAME    Helm release name
#                          (default: grafana-k8s-monitoring)
#   --chart-version VER    Chart version constraint
#                          (default: ^4)
#   --values-file PATH     Path to values YAML
#                          (default: <script-dir>/values.yaml)
#   --uninstall            Uninstall the release instead of installing
#   --dry-run              Render templates only — do not apply
#   --help                 Show this help
#
# Examples:
#   # Install on minikube using the default values + token file
#   ./scripts/grafana-cloud-k8s-monitoring/install.sh --cluster-name local-minikube
#
#   # Install on EKS, override cluster name to differentiate from local
#   kubectl config use-context arn:aws:eks:us-west-2:...:cluster/otel-demo
#   ./scripts/grafana-cloud-k8s-monitoring/install.sh --cluster-name eks-otel-demo
#
#   # Uninstall
#   ./scripts/grafana-cloud-k8s-monitoring/install.sh --uninstall

set -euo pipefail

# ============================================================
# Defaults
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME=""
TOKEN_FILE="${HOME}/.grafana-cloud-token"
NAMESPACE="grafana-k8s-monitoring"
RELEASE_NAME="grafana-k8s-monitoring"
CHART_VERSION="^4"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
UNINSTALL=false
DRY_RUN=false

# ============================================================
# Color output
# ============================================================
if [ -t 1 ] && command -v tput &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

log_info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
log_success() { printf "${GREEN}✓${RESET} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}!${RESET} %s\n" "$*"; }
log_error()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
log_step()    { printf "\n${BOLD}%s${RESET}\n" "$*"; }

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ============================================================
# Parse args
# ============================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name)   CLUSTER_NAME="$2"; shift 2 ;;
    --token-file)     TOKEN_FILE="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --release-name)   RELEASE_NAME="$2"; shift 2 ;;
    --chart-version)  CHART_VERSION="$2"; shift 2 ;;
    --values-file)    VALUES_FILE="$2"; shift 2 ;;
    --uninstall)      UNINSTALL=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --help|-h)        usage 0 ;;
    *)                log_error "Unknown option: $1"; usage 1 ;;
  esac
done

# ============================================================
# Preflight checks
# ============================================================
preflight() {
  log_step "Preflight checks"

  command -v helm >/dev/null    || { log_error "helm not found in PATH";    exit 1; }
  command -v kubectl >/dev/null || { log_error "kubectl not found in PATH"; exit 1; }

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$ctx" ]; then
    log_error "No active kubectl context. Set one with 'kubectl config use-context <name>'."
    exit 1
  fi
  log_info "kubectl context: $ctx"

  if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
    log_error "kubectl cannot reach the cluster API server (context: $ctx)."
    log_error "Check 'kubectl get nodes' and your VPN/credentials."
    exit 1
  fi

  if [ -z "$CLUSTER_NAME" ]; then
    # Default cluster name = kubectl context (sanitized: strip ARN noise, keep last segment)
    CLUSTER_NAME="$(echo "$ctx" | sed -E 's|.*/||; s|[^a-zA-Z0-9_-]|-|g')"
    log_info "Cluster name not provided — defaulting to '$CLUSTER_NAME' (derived from context)"
  fi

  if [ "$UNINSTALL" = false ]; then
    if [ ! -f "$TOKEN_FILE" ]; then
      log_error "Token file not found: $TOKEN_FILE"
      log_error "Create one with:"
      log_error "    read -rs GRAFANA_TOKEN          # paste token + Enter"
      log_error "    printf '%s' \"\$GRAFANA_TOKEN\" > $TOKEN_FILE"
      log_error "    chmod 600 $TOKEN_FILE"
      log_error "    unset GRAFANA_TOKEN"
      exit 1
    fi
    if [ ! -f "$VALUES_FILE" ]; then
      log_error "Values file not found: $VALUES_FILE"
      exit 1
    fi
    # Sanity-check token shape (Grafana Cloud Access Policy tokens start with 'glc_')
    local first4
    first4="$(head -c 4 "$TOKEN_FILE" 2>/dev/null || true)"
    if [ "$first4" != "glc_" ]; then
      log_warn "Token in $TOKEN_FILE does not start with 'glc_' — may not be a Grafana Cloud Access Policy token."
    fi
  fi

  log_success "Preflight passed"
}

# ============================================================
# Uninstall
# ============================================================
do_uninstall() {
  log_step "Uninstalling release '$RELEASE_NAME' from namespace '$NAMESPACE'"

  if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
    log_success "Release uninstalled"
  else
    log_warn "Release '$RELEASE_NAME' not found in namespace '$NAMESPACE' — nothing to uninstall"
  fi

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Namespace '$NAMESPACE' still exists. Delete it manually if you want a clean slate:"
    log_info "    kubectl delete namespace $NAMESPACE"
  fi
}

# ============================================================
# Install
# ============================================================
do_install() {
  log_step "Adding/updating grafana helm repo"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null
  log_success "Helm repo ready"

  log_step "Installing $RELEASE_NAME (chart: grafana/k8s-monitoring $CHART_VERSION)"
  log_info "Cluster name (in Grafana Cloud): $CLUSTER_NAME"
  log_info "Namespace:                       $NAMESPACE"
  log_info "Values file:                     $VALUES_FILE"
  log_info "Token file:                      $TOKEN_FILE"

  # Read token at install time only — never persisted, never logged
  local token
  token="$(cat "$TOKEN_FILE")"

  # Common args shared between dry-run (helm template) and real install (helm upgrade)
  local common_args=(
    --version "$CHART_VERSION"
    --namespace "$NAMESPACE"
    --values "$VALUES_FILE"
    # Cluster identity
    --set-string "cluster.name=$CLUSTER_NAME"
    --set-string "telemetryServices.opencost.opencost.exporter.defaultClusterId=$CLUSTER_NAME"
    # OpenCost reads metrics back from the prometheus destination's auto-generated
    # secret. Secret name is always <destination-name>-<release-name>.
    --set-string "telemetryServices.opencost.opencost.prometheus.existingSecretName=grafana-cloud-metrics-${RELEASE_NAME}"
    # Inject token into all 5 places it's needed (no token in values.yaml)
    --set-string "destinations.grafana-cloud-metrics.auth.password=$token"
    --set-string "destinations.grafana-cloud-logs.auth.password=$token"
    --set-string "destinations.gc-otlp-endpoint.auth.password=$token"
    --set-string "destinations.grafana-cloud-profiles.auth.password=$token"
    --set-string "collectorCommon.alloy.remoteConfig.auth.password=$token"
  )

  if [ "$DRY_RUN" = true ]; then
    # Use `helm template` for dry-run — pure client-side rendering. The chart
    # installs Alloy CRDs and uses them in the same release; `helm install
    # --dry-run` (even =client) tries to validate the rendered Alloy custom
    # resources against the live cluster's discovery cache and fails because
    # the CRDs aren't installed yet. helm template skips that check entirely.
    log_warn "DRY RUN — rendering templates only, not applying"
    local rendered
    rendered="$(helm template "$RELEASE_NAME" grafana/k8s-monitoring \
                  "${common_args[@]}" --include-crds)"
    local total_lines
    total_lines="$(printf '%s\n' "$rendered" | wc -l | tr -d ' ')"
    # Temporarily disable pipefail — head -100 closing the pipe sends SIGPIPE
    # to printf, which with pipefail on would abort the whole script (exit 141).
    set +o pipefail
    printf '%s\n' "$rendered" | head -100
    set -o pipefail
    log_warn "(showing first 100 of $total_lines rendered lines; full render is suppressed for readability)"
    log_success "Dry run complete — no resources applied. Templates rendered cleanly."
    return
  fi

  helm upgrade --install "$RELEASE_NAME" grafana/k8s-monitoring \
    "${common_args[@]}" \
    --create-namespace \
    --atomic \
    --timeout 10m

  log_success "Helm install complete"

  log_step "Pod status in namespace '$NAMESPACE'"
  kubectl get pods -n "$NAMESPACE"

  log_step "Next steps"
  echo "  1. Verify pods reach Running (may take 1–2 min for image pulls):"
  echo "       kubectl get pods -n $NAMESPACE -w"
  echo
  echo "  2. Check Alloy is shipping data:"
  echo "       kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=alloy --tail=30"
  echo
  echo "  3. View your cluster in Grafana Cloud:"
  echo "       https://<your-stack>.grafana.net/a/grafana-k8s-app/navigation/cluster"
  echo "       Look for cluster: $CLUSTER_NAME"
  echo
  echo "  4. To wire the otel-demo app's collector to send through Alloy:"
  echo "       Edit kubernetes/values-local-vanilla.yaml — change the debug exporter"
  echo "       to otlphttp pointing at:"
  echo "         http://<receiver-svc>.${NAMESPACE}.svc.cluster.local:4318"
  echo "       (find <receiver-svc> with: kubectl get svc -n $NAMESPACE | grep receiver)"
}

# ============================================================
# Main
# ============================================================
main() {
  preflight
  if [ "$UNINSTALL" = true ]; then
    do_uninstall
  else
    do_install
  fi
}

main "$@"
