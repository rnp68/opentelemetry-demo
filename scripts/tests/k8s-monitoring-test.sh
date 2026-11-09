#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Tests the activation gate, the data check and the deactivation note of
# scripts/grafana-cloud-k8s-monitoring/install.sh with a fake gcx (no network, no
# cluster). Run: scripts/tests/k8s-monitoring-test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../grafana-cloud-k8s-monitoring/install.sh
source "${HERE}/../grafana-cloud-k8s-monitoring/install.sh"
set +e   # the tests expect some functions to fail

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }
contains() { case "$3" in *"$2"*) echo "ok   $1" ;; *) echo "FAIL $1: [$3] lacks [$2]"; fail=1 ;; esac; }
notcontains() { case "$3" in *"$2"*) echo "FAIL $1: [$3] contains [$2]"; fail=1 ;; *) echo "ok   $1" ;; esac; }

# ---- activation gate (stdin is not a terminal in these runs) ----
ACK_ACTIVATED=false; K8S_MONITORING_ACTIVATED=unknown; ASSUME_YES=false; GRAFANA_STACK_URL=unknown
out="$( (activation_gate) </dev/null 2>&1 )"; rc=$?
check "no acknowledgement, no terminal: stops"          "1" "${rc}"
contains "...and says it starts billing"                 "billing" "${out}"
contains "...and tells how to continue"                  "--i-have-activated" "${out}"

ASSUME_YES=true
out="$( (activation_gate) </dev/null 2>&1 )"; rc=$?
check "--yes does NOT acknowledge billing"              "1" "${rc}"
ASSUME_YES=false

ACK_ACTIVATED=true
out="$( (activation_gate) </dev/null 2>&1 )"; rc=$?
check "--i-have-activated passes"                       "0" "${rc}"
ACK_ACTIVATED=false; K8S_MONITORING_ACTIVATED=true
out="$( (activation_gate) </dev/null 2>&1 )"; rc=$?
check "K8S_MONITORING_ACTIVATED=true passes"            "0" "${rc}"
K8S_MONITORING_ACTIVATED=unknown

GRAFANA_STACK_URL="https://demo.grafana.net/"
check "activation page link is built from the stack URL" "https://demo.grafana.net/a/grafana-k8s-app/home" "$(stack_app_url)"
GRAFANA_STACK_URL=unknown
check "no stack URL: no link"                            "" "$(stack_app_url)"

# ---- data check with a fake gcx ----
GRAFANA_CLOUD_PROM_DATASOURCE_UID=prom; GCX_CONTEXT=fake-stack; CLUSTER=test-cluster; CTX=ctx; K8S_MONITORING_NAMESPACE=ns
FAKE_OUT=""
gcx() { printf '%s' "${FAKE_OUT}"; }

FAKE_OUT='{"data":{"result":[{"metric":{},"values":[[1,"3"]]}]}}'
wait_for_metric 'up' 2 1; check "data present: found"                "0" "$?"
FAKE_OUT='{"data":{"result":[]}}'
SECONDS=0; wait_for_metric 'up' 2 1; rc=$?
check "no data: reports not found"                      "1" "${rc}"
check "no data: waited about the timeout (>=2 s)"       "1" "$([ "${SECONDS}" -ge 2 ] && echo 1 || echo 0)"

NO_VERIFY=false; VERIFY_MINUTES_ARG=""; K8S_MONITORING_VERIFY_MINUTES=1
GCX_CONTEXT=unknown
out="$(verify_cluster_data 2>&1)"; rc=$?
check "GCX_CONTEXT unset: skips without failing"        "0" "${rc}"
contains "...and says it will not guess the stack"      "will not guess" "${out}"
GCX_CONTEXT=fake-stack; NO_VERIFY=true
out="$(verify_cluster_data 2>&1)"; check "--no-verify: silent skip" "" "${out}"
NO_VERIFY=false

# ---- discovery of the stack's connection settings (fake gcx; synthetic IDs) ----
FAKE_CFG='{"version":1,"stacks":{"st":{"grafana":{"server":"https://myslug.grafana.net"}}},"contexts":{"ctxA":{"stack":"st"}}}'
FAKE_STACK='{"stack":{"url":"https://myslug.grafana.net","hmInstancePromUrl":"https://prometheus-prod-01-prod-xx-0.grafana.net","hmInstancePromId":111,"hlInstanceUrl":"https://logs-prod-001.grafana.net","hlInstanceId":222,"hpInstanceUrl":"https://profiles-prod-001.grafana.net","hpInstanceId":333}}'
FAKE_STACK_RC=0
gcx() {
  # Like the real gcx: a GRAFANA_CLOUD_TOKEN in the environment is taken as a (wrong) cloud token.
  if [ -n "${GRAFANA_CLOUD_TOKEN:-}" ]; then printf '%s\n' '{"type":"gcx.error","error":{"summary":"Authentication failed (token from environment)"}}'; return 3; fi
  case "$*" in
    "config view")  printf '%s\n' "${FAKE_CFG}" ;;
    *"cloud stacks get myslug") if [ "${FAKE_STACK_RC}" -eq 0 ]; then printf '%s\n' "${FAKE_STACK}"; else printf '%s\n' '{"type":"gcx.error","error":{"summary":"Authentication failed"}}'; fi ;;
  esac
}
unset_all() { for k in GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER GRAFANA_CLOUD_PROFILES_URL GRAFANA_CLOUD_PROFILES_USER GRAFANA_STACK_URL; do unset "$k"; done; }

unset_all; GCX_CONTEXT=ctxA; export GRAFANA_CLOUD_TOKEN=glc_installer_token   # as load_env does in the real run
discover_stack_settings >/dev/null 2>&1
check "discovery works although GRAFANA_CLOUD_TOKEN is exported (regression)" "https://prometheus-prod-01-prod-xx-0.grafana.net/api/prom/push" "${GRAFANA_CLOUD_METRICS_URL:-}"
unset GRAFANA_CLOUD_TOKEN
unset_all; GCX_CONTEXT=ctxA; discover_stack_settings >/dev/null 2>&1
check "metrics URL = host + /api/prom/push"  "https://prometheus-prod-01-prod-xx-0.grafana.net/api/prom/push" "${GRAFANA_CLOUD_METRICS_URL:-}"
check "metrics user"                          "111" "${GRAFANA_CLOUD_METRICS_USER:-}"
check "logs URL = host + /loki/api/v1/push"   "https://logs-prod-001.grafana.net/loki/api/v1/push" "${GRAFANA_CLOUD_LOGS_URL:-}"
check "logs user"                             "222" "${GRAFANA_CLOUD_LOGS_USER:-}"
check "profiles URL = host + :443"            "https://profiles-prod-001.grafana.net:443" "${GRAFANA_CLOUD_PROFILES_URL:-}"
check "profiles user"                         "333" "${GRAFANA_CLOUD_PROFILES_USER:-}"
check "stack URL"                             "https://myslug.grafana.net" "${GRAFANA_STACK_URL:-}"

unset_all; GRAFANA_CLOUD_LOGS_USER=999; discover_stack_settings >/dev/null 2>&1
check "a value you set is never overwritten"  "999" "${GRAFANA_CLOUD_LOGS_USER}"
check "...while the unset ones are filled"    "111" "${GRAFANA_CLOUD_METRICS_USER:-}"

unset_all; GCX_CONTEXT=unknown; discover_stack_settings >/dev/null 2>&1
check "no GCX_CONTEXT: nothing is looked up"  "" "${GRAFANA_CLOUD_METRICS_URL:-}"

unset_all; GCX_CONTEXT=ctxA; FAKE_STACK_RC=1
out="$(discover_stack_settings 2>&1)"; rc=$?
check "not logged in: continues (rc 0)"       "0" "${rc}"
check "...and fills nothing"                  "" "${GRAFANA_CLOUD_METRICS_URL:-}"
contains "...and tells the user to log in"    "gcx cloud login" "${out}"
FAKE_STACK_RC=0; unset_all

# ---- decommission note ----
GRAFANA_STACK_URL="https://demo.grafana.net"
out="$(print_deactivation_guidance)"
contains "uninstall explains Manage app > Deactivate"   "Manage app" "${out}"
contains "...states it does not delete metrics"         "does not delete any metrics" "${out}"
contains "...links the stack's page"                    "https://demo.grafana.net/a/grafana-k8s-app/home" "${out}"
notcontains "...and does not claim deactivation was done" "has been deactivated" "${out}"

[ "${fail}" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
