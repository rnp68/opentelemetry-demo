#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Renders the Grafana-side assets (SLOs, synthetic monitoring checks, k6 tests)
# from grafana-assets/ into build/grafana-assets/, substituting values from
# .env.local. It only writes local files; it never talks to Grafana Cloud.
#
# Configuration:
#   required  DEMO_TARGET_URL   where Grafana Cloud can reach the shop,
#                               e.g. http://<load-balancer-hostname>:8080
#   optional  DEMO_ENVIRONMENT (default workshop)
#             GRAFANA_CLOUD_PROM_DATASOURCE_UID (default grafanacloud-prom)
#
# Usage: scripts/render-assets.sh [--clean]
#   --clean   delete build/grafana-assets (undo this script)
#
# Applying the rendered files, and verifying the SLO queries first:
# docs/grafana-assets.md

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "${REPO_ROOT}"

OUT="${BUILD_DIR}/grafana-assets"

case "${1:-}" in
  --help|-h) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  --clean)   rm -rf "${OUT}"; log_ok "Removed ${OUT#"${REPO_ROOT}"/}"; exit 0 ;;
  "")        ;;
  *)         die "Unknown option: $1 (see --help)" ;;
esac

log_step "Preflight"
check_env_file
load_env
require_vars DEMO_TARGET_URL
case "${DEMO_TARGET_URL}" in
  http://*|https://*) ;;
  *) die "DEMO_TARGET_URL must start with http:// or https:// (got '${DEMO_TARGET_URL}')." ;;
esac
# A trailing slash would produce '//api/...'.
DEMO_TARGET_URL="${DEMO_TARGET_URL%/}"
export DEMO_TARGET_URL
case "${DEMO_TARGET_URL}" in
  *localhost*|*127.0.0.1*)
    log_warn "DEMO_TARGET_URL points at this machine; Grafana Cloud probes cannot reach it."
    log_warn "Synthetic checks need a public address (see docs/grafana-assets.md)." ;;
esac

log_step "Rendering to ${OUT#"${REPO_ROOT}"/}"
rm -rf "${OUT}"
mkdir -p "${OUT}/slo" "${OUT}/synthetic-checks" "${OUT}/k6/schedules"
rendered=0
for f in grafana-assets/slo/*.yaml grafana-assets/synthetic-checks/*.yaml; do
  dst="${OUT}/${f#grafana-assets/}"
  render_template "${f}" "${dst}" || die "Unresolved placeholders in ${f}."
  rendered=$((rendered + 1))
done
cp grafana-assets/k6/*.js "${OUT}/k6/"
cp grafana-assets/k6/schedules/*.yaml "${OUT}/k6/schedules/"
log_ok "${rendered} templates rendered; k6 files copied"

if command -v yq >/dev/null 2>&1; then
  for f in "${OUT}"/slo/*.yaml "${OUT}"/synthetic-checks/*.yaml; do
    yq '.' "${f}" >/dev/null 2>&1 || die "Rendered file is not valid YAML: ${f#"${REPO_ROOT}"/}"
  done
  log_ok "Rendered YAML parses"
else
  log_warn "yq not found; skipped the YAML syntax check (brew install yq)."
fi

cat <<EOF2

Rendered files are in ${OUT#"${REPO_ROOT}"/}/.

Next (see docs/grafana-assets.md for details and for verifying the queries):
  1. SLOs:             gcx resources push slos.v1alpha1.slo.ext.grafana.app -p ${OUT#"${REPO_ROOT}"/}/slo --dry-run
  2. Synthetic checks: gcx synthetic-monitoring checks create --help   (one file per check)
  3. k6 tests:         gcx k6 load-tests create --help                 (files in ${OUT#"${REPO_ROOT}"/}/k6)
Undo (local files only):  scripts/render-assets.sh --clean
EOF2
