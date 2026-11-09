#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Writes build/env.resolved from .env.local without deploying anything. Use it for the
# manual deployment route (docs/manual-deployment.md): that file is what Docker Compose must
# receive, because the raw .env.local would pass the placeholder "unknown" (and any text
# after a value) into the containers.
#
# Usage: scripts/make-env.sh [--check]
#   (no option)  create .env.local from .env.example if missing, then write build/env.resolved
#   --check      only report which values are set; write nothing (secrets are never printed)
#   --clean      delete build/env.resolved
#
# The file is mode 0600 and git-ignored. It contains your secrets: never paste it anywhere.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

case "${1:-}" in
  --help|-h) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  --clean)   rm -f "${ENV_RESOLVED}"; log_ok "Removed ${ENV_RESOLVED#"${REPO_ROOT}"/}"; exit 0 ;;
  --check|"") ;;
  *) die "Unknown option: $1 (see --help)" ;;
esac

[ "${1:-}" = "--check" ] || check_env_file
load_env

echo "Effective configuration (secrets are shown only as set / not set):"
for key in $(env_example_keys); do
  eval "val=\"\${${key}:-}\""
  case "${key}" in
    *APIKEY*|*TOKEN*|*PASS*) shown="$(is_unset "${val}" && echo 'not set' || echo "set (${#val} chars)")" ;;
    *) shown="$(is_unset "${val}" && echo 'not set' || echo "${val}")" ;;
  esac
  printf '  %-36s %s\n' "${key}" "${shown}"
done

if [ "${1:-}" != "--check" ]; then
  write_resolved_env
  log_ok "Wrote ${ENV_RESOLVED#"${REPO_ROOT}"/} (mode 0600). Pass it to Docker Compose with:"
  echo "    docker compose --env-file .env --env-file build/env.resolved ..."
fi
