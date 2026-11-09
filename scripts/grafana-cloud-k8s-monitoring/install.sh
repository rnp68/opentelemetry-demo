#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs the grafana/k8s-monitoring Helm chart (v4.x) into a Kubernetes cluster
# so that the cluster itself (nodes, pods, events, logs, costs, profiles) shows up
# in Grafana Cloud. It also provides the Alloy receiver used by
# `./start-local.sh --k8s-alloy-forward`.
#
# Configuration (from .env.local; template .env.example):
#   required  GRAFANA_CLOUD_TOKEN  GRAFANA_OTLP_ENDPOINT  GRAFANA_INSTANCE_ID
#             GRAFANA_CLOUD_METRICS_URL  GRAFANA_CLOUD_METRICS_USER
#             GRAFANA_CLOUD_LOGS_URL     GRAFANA_CLOUD_LOGS_USER
#             GRAFANA_CLOUD_PROFILES_URL GRAFANA_CLOUD_PROFILES_USER
#   optional  K8S_CLUSTER_NAME  K8S_MONITORING_CHART_VERSION (default 4.6.0)
#             K8S_MONITORING_NAMESPACE  K8S_MONITORING_RELEASE  K8S_CONTEXT
#
# The token needs the scopes metrics:write, logs:write, traces:write and
# profiles:write. It is written to a temporary 0600 values file (never passed on
# the command line, so it does not appear in `ps`) that is deleted on exit.
#
# Usage: scripts/grafana-cloud-k8s-monitoring/install.sh [OPTIONS]
#
#   --cluster-name NAME   cluster identifier in Grafana Cloud
#                         (default: K8S_CLUSTER_NAME, then the kubectl context)
#   --context NAME        kubectl context (default: K8S_CONTEXT, else the current one)
#   --uninstall           remove the release (undeploy)
#   --dry-run             render the chart only; change nothing in the cluster
#   --yes                 do not ask for confirmation
#   --help
#
# Manual equivalent: docs/grafana-cloud-k8s-monitoring.md

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
cd "${REPO_ROOT}"

CLUSTER_NAME_ARG=""
CONTEXT_ARG=""
UNINSTALL=false
DRY_RUN=false
ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME_ARG="${2:?--cluster-name needs a value}"; shift ;;
    --context)      CONTEXT_ARG="${2:?--context needs a value}"; shift ;;
    --uninstall)    UNINSTALL=true ;;
    --dry-run)      DRY_RUN=true ;;
    --yes|-y)       ASSUME_YES=true ;;
    --help|-h)      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done
export ASSUME_YES

SECRETS_FILE="${BUILD_DIR}/k8s-monitoring-secrets.yaml"
VALUES_FILE="${BUILD_DIR}/k8s-monitoring-values.yaml"
cleanup() { rm -f "${SECRETS_FILE}"; }
trap cleanup EXIT

preflight() {
  log_step "Preflight"
  check_env_file
  load_env
  require_cmd helm "https://helm.sh/docs/intro/install/ (brew install helm)" || exit 1
  require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/ (brew install kubectl)" || exit 1

  CTX="${CONTEXT_ARG}"
  is_unset "${CTX}" && CTX="${K8S_CONTEXT:-}"
  is_unset "${CTX}" && CTX="$(kubectl config current-context 2>/dev/null || true)"
  [ -n "${CTX}" ] || die "No kubectl context. Create a cluster or run: kubectl config use-context <name>"
  KUBECTL=( kubectl --context "${CTX}" )
  HELM=( helm --kube-context "${CTX}" )
  "${KUBECTL[@]}" version --request-timeout=5s >/dev/null 2>&1 || die "Cannot reach the cluster of context '${CTX}'. Is it running / are you on the VPN?"
  log_ok "Kubernetes context: ${CTX}"

  CLUSTER="${CLUSTER_NAME_ARG}"
  is_unset "${CLUSTER}" && CLUSTER="${K8S_CLUSTER_NAME:-}"
  is_unset "${CLUSTER}" && CLUSTER="$(printf '%s' "${CTX}" | sed -E 's|.*/||; s|[^a-zA-Z0-9_-]|-|g')"
  log_info "Cluster name in Grafana Cloud: ${CLUSTER}"
}

do_uninstall() {
  log_step "Uninstalling ${K8S_MONITORING_RELEASE} from ${K8S_MONITORING_NAMESPACE}"
  if "${HELM[@]}" status "${K8S_MONITORING_RELEASE}" -n "${K8S_MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    confirm "Remove release ${K8S_MONITORING_RELEASE} from context ${CTX}?" || { log_info "Cancelled."; exit 0; }
    "${HELM[@]}" uninstall "${K8S_MONITORING_RELEASE}" -n "${K8S_MONITORING_NAMESPACE}" --wait --timeout 5m
    log_ok "Release uninstalled"
  else
    log_warn "Release ${K8S_MONITORING_RELEASE} not found in ${K8S_MONITORING_NAMESPACE}; nothing to remove."
  fi
  if "${KUBECTL[@]}" get namespace "${K8S_MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Namespace ${K8S_MONITORING_NAMESPACE} still exists. For a clean slate:"
    log_info "    kubectl --context ${CTX} delete namespace ${K8S_MONITORING_NAMESPACE}"
  fi
}

do_install() {
  require_vars GRAFANA_CLOUD_TOKEN GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID \
    GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER \
    GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER \
    GRAFANA_CLOUD_PROFILES_URL GRAFANA_CLOUD_PROFILES_USER

  case "${GRAFANA_CLOUD_TOKEN}" in
    glc_*) ;;
    *) log_warn "GRAFANA_CLOUD_TOKEN does not start with 'glc_'; it may not be a Grafana Cloud access policy token." ;;
  esac

  # OpenCost reads metrics back from the Prometheus query endpoint, which is the
  # push URL without the trailing /push.
  GRAFANA_CLOUD_METRICS_QUERY_URL="${GRAFANA_CLOUD_METRICS_URL%/push}"
  export GRAFANA_CLOUD_METRICS_QUERY_URL

  log_step "Rendering the values"
  mkdir -p "${BUILD_DIR}"
  render_template scripts/grafana-cloud-k8s-monitoring/values.yaml.tmpl "${VALUES_FILE}" \
    || die "Some placeholders in values.yaml.tmpl are unresolved (see above)."
  # Only the secrets go to this file; it is removed on exit.
  ( umask 077; cat > "${SECRETS_FILE}" <<EOF
destinations:
  grafana-cloud-metrics:
    auth:
      password: "${GRAFANA_CLOUD_TOKEN}"
  grafana-cloud-logs:
    auth:
      password: "${GRAFANA_CLOUD_TOKEN}"
  gc-otlp-endpoint:
    auth:
      password: "${GRAFANA_CLOUD_TOKEN}"
  grafana-cloud-profiles:
    auth:
      password: "${GRAFANA_CLOUD_TOKEN}"
collectorCommon:
  alloy:
    remoteConfig:
      auth:
        password: "${GRAFANA_CLOUD_TOKEN}"
EOF
  )
  log_ok "Values rendered to ${VALUES_FILE#"${REPO_ROOT}"/}"

  "${HELM[@]}" repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  "${HELM[@]}" repo update grafana >/dev/null

  local common_args=(
    --version "${K8S_MONITORING_CHART_VERSION}"
    --namespace "${K8S_MONITORING_NAMESPACE}"
    -f "${VALUES_FILE}"
    -f "${SECRETS_FILE}"
    --set-string "cluster.name=${CLUSTER}"
    --set-string "telemetryServices.opencost.opencost.exporter.defaultClusterId=${CLUSTER}"
    # The destination secret is named <destination>-<release>.
    --set-string "telemetryServices.opencost.opencost.prometheus.existingSecretName=grafana-cloud-metrics-${K8S_MONITORING_RELEASE}"
  )

  if [ "${DRY_RUN}" = true ]; then
    log_warn "DRY RUN: rendering templates only; nothing is applied."
    local rendered lines
    # helm template (not install --dry-run): the chart installs Alloy CRDs and uses
    # them in the same release, which --dry-run cannot validate before they exist.
    rendered="$("${HELM[@]}" template "${K8S_MONITORING_RELEASE}" grafana/k8s-monitoring "${common_args[@]}" --include-crds)"
    lines="$(printf '%s\n' "${rendered}" | wc -l | tr -d ' ')"
    log_ok "Chart rendered cleanly (${lines} lines, $(printf '%s\n' "${rendered}" | grep -c '^kind:') objects)."
    return 0
  fi

  if "${HELM[@]}" status "${K8S_MONITORING_RELEASE}" -n "${K8S_MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Release ${K8S_MONITORING_RELEASE} already exists; upgrading in place."
  fi
  log_step "Installing ${K8S_MONITORING_RELEASE} (grafana/k8s-monitoring ${K8S_MONITORING_CHART_VERSION}) into ${K8S_MONITORING_NAMESPACE}"
  "${HELM[@]}" upgrade --install "${K8S_MONITORING_RELEASE}" grafana/k8s-monitoring \
    "${common_args[@]}" --create-namespace --atomic --timeout 10m
  log_ok "Helm install complete"

  log_step "Pod status"
  "${KUBECTL[@]}" get pods -n "${K8S_MONITORING_NAMESPACE}"

  cat <<EOF

Next steps
  1. Wait until the pods are Running (1-2 minutes for image pulls):
       kubectl --context ${CTX} get pods -n ${K8S_MONITORING_NAMESPACE} -w
  2. Check Alloy is shipping data:
       kubectl --context ${CTX} logs -n ${K8S_MONITORING_NAMESPACE} -l app.kubernetes.io/name=alloy --tail=30
  3. In Grafana Cloud open Kubernetes > Cluster navigation and look for cluster "${CLUSTER}".
  4. To make the demo send its telemetry through this Alloy:
       ./start-local.sh --k8s-alloy-forward
  Undeploy:  scripts/grafana-cloud-k8s-monitoring/install.sh --uninstall
  Manual:    docs/grafana-cloud-k8s-monitoring.md
EOF
}

preflight
if [ "${UNINSTALL}" = true ]; then do_uninstall; else do_install; fi
