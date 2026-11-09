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
#             GRAFANA_STACK_URL (link to the activation page), GCX_CONTEXT (gcx context of this
#             stack: enables the automatic data check AND fills in the unset GRAFANA_CLOUD_*_URL/_USER
#             values from the stack, after `gcx cloud login`), K8S_MONITORING_ACTIVATED
#
# Before the first install, activate Kubernetes Monitoring once in the Grafana Cloud UI
# (it enables host/container-hour billing; the app stays empty until then). See
# docs/grafana-cloud-k8s-monitoring.md.
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
#   --i-have-activated    you activated Kubernetes Monitoring in the Grafana UI (see below);
#                         same as K8S_MONITORING_ACTIVATED=true. Required when not run from a terminal
#   --no-verify           do not wait for cluster data in Grafana Cloud after the install
#   --verify-minutes N    how long to wait for it (default K8S_MONITORING_VERIFY_MINUTES, 6)
#   --uninstall           remove the release (undeploy) and explain how to deactivate the app
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
ACK_ACTIVATED=false
NO_VERIFY=false
VERIFY_MINUTES_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME_ARG="${2:?--cluster-name needs a value}"; shift ;;
    --context)      CONTEXT_ARG="${2:?--context needs a value}"; shift ;;
    --uninstall)    UNINSTALL=true ;;
    --i-have-activated) ACK_ACTIVATED=true ;;
    --no-verify)    NO_VERIFY=true ;;
    --verify-minutes) VERIFY_MINUTES_ARG="${2:?--verify-minutes needs a value}"; shift ;;
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

# gcx_clean: runs gcx without GRAFANA_CLOUD_TOKEN in its environment. gcx reads that
# variable as its own Grafana Cloud API token and then rejects its login (HTTP 401), but
# here it holds the access-policy token for the Helm chart.
gcx_clean() { ( unset GRAFANA_CLOUD_TOKEN; gcx "$@" ); }

# discover_stack_settings: fills the connection values that are still unset (never
# overwrites one you set) from the stack itself, with `gcx cloud stacks get`. Needs
# gcx, an explicit GCX_CONTEXT and a `gcx cloud login` for that context. The token is
# NOT discoverable: create it in the UI (see docs/grafana-cloud-k8s-monitoring.md).
discover_stack_settings() {
  is_unset "${GCX_CONTEXT:-}" && return 0
  command -v gcx >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local need=0 k v
  for k in GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER \
           GRAFANA_CLOUD_PROFILES_URL GRAFANA_CLOUD_PROFILES_USER GRAFANA_STACK_URL; do
    eval "v=\"\${${k}:-}\""; is_unset "${v}" && need=1
  done
  [ "${need}" -eq 0 ] && return 0

  local slug cfg stack
  cfg="$(gcx_clean config view 2>/dev/null || true)"
  slug="$(printf '%s' "${cfg}" | GCX_CONTEXT="${GCX_CONTEXT}" python3 -c '
import sys,json,os,re
ctx=os.environ["GCX_CONTEXT"]
for l in sys.stdin:
    l=l.strip()
    if l.startswith("{\"version\""):
        d=json.loads(l); st=(d.get("contexts",{}).get(ctx) or {}).get("stack")
        srv=((d.get("stacks",{}).get(st) or {}).get("grafana") or {}).get("server","")
        m=re.match(r"https?://([^./]+)\.grafana\.net",srv)
        print(m.group(1) if m else "")
' 2>/dev/null || true)"
  if [ -z "${slug}" ]; then
    log_warn "gcx context '${GCX_CONTEXT}' has no <slug>.grafana.net server; cannot look up the stack settings."
    return 0
  fi
  stack="$(gcx_clean --context "${GCX_CONTEXT}" cloud stacks get "${slug}" 2>/dev/null || true)"
  local lines
  lines="$(printf '%s' "${stack}" | python3 -c '
import sys,json
d=None
for l in sys.stdin:
    l=l.strip()
    if l.startswith("{"):
        try: d=json.loads(l); break
        except Exception: pass
if not d or "error" in d: sys.exit(1)
d=d.get("stack",d)
g=lambda k: str(d.get(k,"") or "")
out={
 "GRAFANA_CLOUD_METRICS_URL": g("hmInstancePromUrl")+"/api/prom/push" if g("hmInstancePromUrl") else "",
 "GRAFANA_CLOUD_METRICS_USER": g("hmInstancePromId"),
 "GRAFANA_CLOUD_LOGS_URL": g("hlInstanceUrl")+"/loki/api/v1/push" if g("hlInstanceUrl") else "",
 "GRAFANA_CLOUD_LOGS_USER": g("hlInstanceId"),
 "GRAFANA_CLOUD_PROFILES_URL": g("hpInstanceUrl")+":443" if g("hpInstanceUrl") else "",
 "GRAFANA_CLOUD_PROFILES_USER": g("hpInstanceId"),
 "GRAFANA_STACK_URL": g("url"),
}
for k,v in out.items():
    if v: print(k+"="+v)
' 2>/dev/null)" || {
    log_warn "Could not read stack '${slug}' with gcx (not logged in? run: gcx cloud login). Continuing with .env.local."
    return 0
  }
  local line key val filled=""
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    key="${line%%=*}"; val="${line#*=}"
    eval "v=\"\${${key}:-}\""
    if is_unset "${v}"; then export "${key}=${val}"; filled="${filled} ${key}"; fi
  done <<EOL
${lines}
EOL
  if [ -n "${filled}" ]; then
    log_ok "Filled from stack '${slug}' (gcx context '${GCX_CONTEXT}'):${filled}"
  fi
}

# ── Activation, verification, deactivation guidance ─────────────────────────

stack_app_url() {
  local u="${GRAFANA_STACK_URL:-}"
  if is_unset "${u}"; then echo ""; else echo "${u%/}/a/grafana-k8s-app/home"; fi
}

# activation_gate: Kubernetes Monitoring must be activated once in the Grafana UI;
# activation is what starts host/container-hour billing, and Grafana offers no API
# for it, so this script cannot do it. The gate (1) explains it, (2) can open the
# page, (3) needs the user's own confirmation: --yes does NOT answer it.
activation_gate() {
  local url
  url="$(stack_app_url)"
  log_step "Kubernetes Monitoring activation (your action, in the Grafana UI)"
  cat <<EOM
  Grafana Cloud's Kubernetes Monitoring app stays empty until it is activated once.
  Activation also starts billing on active host hours and active container hours,
  metered from kube-state-metrics (https://grafana.com/docs/grafana-cloud/platform/pricing-and-usage/kubernetes-monitoring/).
  This script cannot activate it for you (there is no API); you do it in the browser:
    1. Open ${url:-your stack, then Kubernetes (set GRAFANA_STACK_URL in .env.local for a direct link)}
    2. Click "Activate", tick the box in the dialog, click "Activate".
EOM
  if [ "${ACK_ACTIVATED}" = "true" ] || [ "${K8S_MONITORING_ACTIVATED:-}" = "true" ]; then
    log_ok "Activation acknowledged (--i-have-activated / K8S_MONITORING_ACTIVATED=true)."
    return 0
  fi
  if [ ! -t 0 ]; then
    log_error "Not running in a terminal, so I cannot ask. After activating, run again with --i-have-activated"
    log_error "(or set K8S_MONITORING_ACTIVATED=true in .env.local). --yes does not acknowledge billing."
    exit 1
  fi
  if [ -n "${url}" ] && command -v open >/dev/null 2>&1 && confirm_strict "Open that page in your browser now?"; then
    open "${url}" || true
  fi
  confirm_strict "Have you activated Kubernetes Monitoring in the UI (this starts billing)?" || {
    log_error "Not confirmed. Activate it, then run this script again (it continues from here)."
    exit 1
  }
  log_ok "Activation confirmed by you."
}

# wait_for_metric EXPR SECONDS INTERVAL: polls Prometheus (through gcx, using the
# explicit GCX_CONTEXT) until EXPR returns at least one series. 0 = found, 1 = not.
wait_for_metric() {
  local expr="$1" total="$2" every="$3" waited=0 out
  while :; do
    out="$(gcx_clean --context "${GCX_CONTEXT}" metrics query -d "${GRAFANA_CLOUD_PROM_DATASOURCE_UID}" "${expr}" --since 10m -o json 2>/dev/null || true)"
    if printf '%s' "${out}" | grep -q '"values"'; then return 0; fi
    [ "${waited}" -ge "${total}" ] && return 1
    sleep "${every}"
    waited=$(( waited + every ))
  done
}

# verify_cluster_data: after the install, waits for this cluster's kube_pod_info in
# the stack. Only runs when GCX_CONTEXT is set (never guesses which stack to read).
verify_cluster_data() {
  [ "${NO_VERIFY}" = "true" ] && return 0
  if ! command -v gcx >/dev/null 2>&1; then
    log_warn "gcx not found: check by hand that Kubernetes > Cluster navigation lists '${CLUSTER}'."
    return 0
  fi
  if is_unset "${GCX_CONTEXT:-}"; then
    log_warn "GCX_CONTEXT is not set, so I do not check the data automatically (I will not guess which stack to read)."
    log_warn "Set GCX_CONTEXT to the gcx context of this stack, or check by hand in Kubernetes > Cluster navigation."
    return 0
  fi
  local minutes="${VERIFY_MINUTES_ARG:-${K8S_MONITORING_VERIFY_MINUTES}}"
  local server
  server="$(gcx_clean config view 2>/dev/null | python3 -c '
import sys,json,os
ctx=os.environ.get("GCX_CONTEXT","")
for l in sys.stdin:
    l=l.strip()
    if l.startswith("{\"version\""):
        d=json.loads(l); st=(d.get("contexts",{}).get(ctx) or {}).get("stack")
        print(((d.get("stacks",{}).get(st) or {}).get("grafana") or {}).get("server",""))
' 2>/dev/null || true)"
  log_step "Checking that cluster data arrives (gcx context '${GCX_CONTEXT}'${server:+, ${server}}), up to ${minutes} min"
  if wait_for_metric "count(kube_pod_info{cluster=\"${CLUSTER}\"})" $(( minutes * 60 )) 15; then
    log_ok "kube_pod_info for cluster '${CLUSTER}' is in Grafana Cloud: cluster data arrives."
  else
    log_warn "No kube_pod_info for cluster '${CLUSTER}' after ${minutes} minutes. Possible reasons:"
    log_warn "  - Kubernetes Monitoring is not activated yet (the app's home page shows an Activate panel);"
    log_warn "  - the pods are still starting: kubectl --context ${CTX} get pods -n ${K8S_MONITORING_NAMESPACE};"
    log_warn "  - the collectors cannot send: kubectl --context ${CTX} logs -n ${K8S_MONITORING_NAMESPACE} -l app.kubernetes.io/name=alloy --tail=30;"
    log_warn "  - GCX_CONTEXT '${GCX_CONTEXT}' points to another stack than the destinations in .env.local."
  fi
}

print_deactivation_guidance() {
  local url
  url="$(stack_app_url)"
  cat <<EOM

Decommission note: this removed the collectors, so no more kube-state-metrics are sent. Per the
Grafana docs a host or container counts as active only if kube-state-metrics reported it within the
last 15 minutes, so usage stops accruing on its own. Activation itself stays on. To switch the app
off (also a UI-only step, it does not delete any metrics):
    ${url:-your stack > Kubernetes}  >  Configuration  >  Manage app  >  Deactivate
EOM
}

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
  print_deactivation_guidance
}

do_install() {
  discover_stack_settings
  require_vars GRAFANA_CLOUD_TOKEN GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID \
    GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER \
    GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER \
    GRAFANA_CLOUD_PROFILES_URL GRAFANA_CLOUD_PROFILES_USER

  [ "${DRY_RUN}" = true ] || activation_gate

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

  verify_cluster_data

  cat <<EOF

Next steps
  1. Wait until the pods are Running (1-2 minutes for image pulls):
       kubectl --context ${CTX} get pods -n ${K8S_MONITORING_NAMESPACE} -w
  2. Check Alloy is shipping data:
       kubectl --context ${CTX} logs -n ${K8S_MONITORING_NAMESPACE} -l app.kubernetes.io/name=alloy --tail=30
  3. In Grafana Cloud open Kubernetes > Cluster navigation and look for cluster "${CLUSTER}".
     If the app only shows "Activate Kubernetes Monitoring", click Activate once (it starts
     host/container-hour billing); the installed collectors will then show up.
  4. To make the demo send its telemetry through this Alloy:
       ./start-local.sh --k8s-alloy-forward
  Undeploy:  scripts/grafana-cloud-k8s-monitoring/install.sh --uninstall
  Manual:    docs/grafana-cloud-k8s-monitoring.md
EOF
}

# Allow `source install.sh` (used by the tests) without running anything.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0; fi

preflight
if [ "${UNINSTALL}" = true ]; then do_uninstall; else do_install; fi
