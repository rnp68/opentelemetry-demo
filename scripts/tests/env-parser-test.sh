#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Tests parse_env_file from scripts/lib/common.sh. Run: scripts/tests/env-parser-test.sh
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
cat > "${tmp}" <<'ENVEOF'
# a comment
GRAFANA_INSTANCE_ID= 12345      # stray space after =, inline comment
GRAFANA_OTLP_ENDPOINT="https://otlp.example/otlp"   # quoted
GRAFANA_CLOUD_APIKEY='glc_ab$cd&ef#gh'
GRAFANA_FARO_ENDPOINT=https://faro.example/collect/x#frag
lowercase=ignored
GRAFANA_PYROSCOPE_ADDR=unknown
GRAFANA_CLOUD_LOGS_URL=https://logs.example/push  which# leftover text
GRAFANA_CLOUD_LOGS_USER=777   # normal comment
GRAFANA_CLOUD_METRICS_USER="has space"
ENVEOF

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}
parse_env_file "${tmp}" >/dev/null 2>&1
check "stray space after ="            "12345"                       "${GRAFANA_INSTANCE_ID}"
check "double quotes"                  "https://otlp.example/otlp"   "${GRAFANA_OTLP_ENDPOINT}"
check "single quotes keep \$ & #"      'glc_ab$cd&ef#gh'             "${GRAFANA_CLOUD_APIKEY}"
check "# inside a URL is kept"         "https://faro.example/collect/x#frag" "${GRAFANA_FARO_ENDPOINT}"
check "lowercase keys are ignored"     ""                            "${lowercase:-}"
check "placeholder is passed through"  "unknown"                     "${GRAFANA_PYROSCOPE_ADDR}"
check "extra text after value dropped" "https://logs.example/push"   "${GRAFANA_CLOUD_LOGS_URL}"
check "inline comment dropped"         "777"                         "${GRAFANA_CLOUD_LOGS_USER}"
check "quoted value keeps its space"   "has space"                   "${GRAFANA_CLOUD_METRICS_USER}"
warn="$(parse_env_file "${tmp}" 2>&1 || true)"   # log_warn prints to stdout
case "${warn}" in *"ignored extra text"*GRAFANA_CLOUD_LOGS_URL*) echo "ok   warns about dropped text" ;; *) echo "FAIL no warning for dropped text"; fail=1 ;; esac
[ "${fail}" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
