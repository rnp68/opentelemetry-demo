#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Tests token_region and check_grafana_cloud_credentials with a fake curl (no
# network, no real credentials). Run: scripts/tests/credential-check-test.sh
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }
mk_token() { printf 'glc_%s' "$(printf '{"o":"1","n":"test","k":"FAKE-SECRET","m":{"r":"%s"}}' "$1" | base64 | tr -d '\n=' | tr '+/' '-_')"; }

check "region is read from the token"   "prod-us-east-0" "$(token_region "$(mk_token prod-us-east-0)")"
check "garbage token gives empty"       ""               "$(token_region 'glc_not-base64!!' 2>/dev/null)"

GRAFANA_CLOUD_APIKEY="$(mk_token prod-us-east-0)"
GRAFANA_INSTANCE_ID=1
GRAFANA_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-2.grafana.net/otlp"   # region differs from the token field on purpose

FAKE_CODE=200
curl() { cat >/dev/null; printf '%s' "${FAKE_CODE}"; }   # stands in for curl; ignores its arguments

run() { set +e; out="$( (check_grafana_cloud_credentials) 2>&1 )"; rc=$?; set -e; }

FAKE_CODE=200; run
check "200 passes even though the token field differs from the endpoint region (regression)" "0" "${rc}"
FAKE_CODE=204; run;  check "204 passes"                        "0" "${rc}"
FAKE_CODE=401; run;  check "401 stops"                          "1" "${rc}"
case "${out}" in *"inside that stack"*"hint only"*prod-us-east-0*) echo "ok   401 message names the likely cause and the region hint" ;; *) echo "FAIL 401 message: ${out}"; fail=1 ;; esac
case "${out}" in *FAKE-SECRET*) echo "FAIL the secret part was printed"; fail=1 ;; *) echo "ok   secret part is never printed" ;; esac
FAKE_CODE=403; run;  check "403 stops"                          "1" "${rc}"
FAKE_CODE=000; run;  check "unreachable only warns"             "0" "${rc}"
FAKE_CODE=500; run;  check "unexpected answer only warns"       "0" "${rc}"
SKIP_CREDENTIAL_CHECK=true; FAKE_CODE=401; run; check "SKIP_CREDENTIAL_CHECK=true skips" "0" "${rc}"

[ "${fail}" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
