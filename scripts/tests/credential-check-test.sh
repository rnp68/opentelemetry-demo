#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Tests token_region and the region-mismatch stop of
# check_grafana_cloud_credentials (no network, no real credentials).
# Run: scripts/tests/credential-check-test.sh
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }

mk_token() { # region -> a glc_ token with a fake secret part
  printf 'glc_%s' "$(printf '{"o":"1","n":"test","k":"FAKE-SECRET","m":{"r":"%s"}}' "$1" | base64 | tr -d '\n=' | tr '+/' '-_')"
}

check "region is read from the token"        "prod-us-east-0" "$(token_region "$(mk_token prod-us-east-0)")"
check "other region"                          "prod-eu-west-2" "$(token_region "$(mk_token prod-eu-west-2)")"
check "garbage token gives empty region"      ""               "$(token_region 'glc_not-base64!!' 2>/dev/null)"
check "token without glc_ prefix"             ""               "$(token_region 'abc' 2>/dev/null)"

GRAFANA_CLOUD_APIKEY="$(mk_token prod-us-east-0)"
GRAFANA_INSTANCE_ID=1
GRAFANA_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-2.grafana.net/otlp"
set +e
out="$( (check_grafana_cloud_credentials) 2>&1 )"; rc=$?
set -e
check "region mismatch exits 1"               "1" "${rc}"
case "${out}" in *"prod-us-east-0"*"prod-us-east-2"*) echo "ok   message names both regions" ;; *) echo "FAIL message: ${out}"; fail=1 ;; esac
case "${out}" in *FAKE-SECRET*) echo "FAIL the secret part was printed"; fail=1 ;; *) echo "ok   secret part is never printed" ;; esac

GRAFANA_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-0.grafana.net/otlp"
SKIP_CREDENTIAL_CHECK=true
set +e; (check_grafana_cloud_credentials) >/dev/null 2>&1; rc=$?; set -e
check "SKIP_CREDENTIAL_CHECK=true skips"      "0" "${rc}"

[ "${fail}" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
