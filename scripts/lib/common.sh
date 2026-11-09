#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for the workshop scripts. Source it; do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Compatible with the bash 3.2 that ships with macOS (no associative arrays).
#
# Configuration model (see docs/configuration.md):
#   1. every variable is listed in .env.example (tracked, all values "unknown")
#   2. real values live in .env.local (gitignored) or in the shell environment
#   3. "" and "unknown" mean "not set" -> built-in default (default_for) or, for
#      values without a safe default, require_vars stops with instructions
#   4. write_resolved_env writes the effective values to build/env.resolved,
#      which is what docker compose receives (so "unknown" never leaks into a
#      container)

[ -n "${WORKSHOP_COMMON_LOADED:-}" ] && return 0
WORKSHOP_COMMON_LOADED=1

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
ENV_LOCAL="${REPO_ROOT}/.env.local"
ENV_RESOLVED="${BUILD_DIR}/env.resolved"

# ── Output ───────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi
log_info()    { printf '%s\n' "${BLUE}→${RESET} $*"; }
log_ok()      { printf '%s\n' "${GREEN}✓${RESET} $*"; }
log_warn()    { printf '%s\n' "${YELLOW}!${RESET} $*"; }
log_error()   { printf '%s\n' "${RED}✗${RESET} $*" >&2; }
log_step()    { printf '\n%s\n' "${BOLD}$*${RESET}"; }
die()         { log_error "$*"; exit 1; }

# ── Value handling ───────────────────────────────────────────────────────────
# True when a value is empty or the "unknown" placeholder from .env.example.
is_unset() { [ -z "${1:-}" ] || [ "${1}" = "unknown" ]; }

# Built-in defaults for tunables that have a safe default. Secrets and
# account-specific values (endpoints, IDs, tokens) deliberately have none.
default_for() {
  case "$1" in
    OTEL_DEMO_CHART_VERSION)        echo "0.37.8" ;;
    DEMO_VERSION)                   echo "2.0.2" ;;
    OTEL_DEMO_NAMESPACE)            echo "otel-demo" ;;
    OTEL_DEMO_RELEASE)              echo "opentelemetry-demo" ;;
    MINIKUBE_CPUS)                  echo "4" ;;
    MINIKUBE_MEMORY_MB)             echo "8192" ;;
    LOCUST_USERS)                   echo "5" ;;
    EKS_CLUSTER_NAME)               echo "otel-demo" ;;
    EKS_K8S_VERSION)                echo "1.33" ;;
    EKS_NODE_TYPE)                  echo "t3.xlarge" ;;
    EKS_NODE_COUNT)                 echo "2" ;;
    EKS_NODE_MIN)                   echo "1" ;;
    EKS_NODE_MAX)                   echo "4" ;;
    AWS_RESOURCE_TAG_KEY)           echo "project" ;;
    AWS_RESOURCE_TAG_VALUE)         echo "opentelemetry-demo" ;;
    K8S_MONITORING_CHART_VERSION)   echo "4.6.0" ;;
    K8S_MONITORING_NAMESPACE)       echo "grafana-k8s-monitoring" ;;
    K8S_MONITORING_RELEASE)         echo "grafana-k8s-monitoring" ;;
    ALLOY_CHART_VERSION)            echo "1.8.1" ;;
    DEMO_ENVIRONMENT)               echo "workshop" ;;
    GRAFANA_CLOUD_PROM_DATASOURCE_UID) echo "grafanacloud-prom" ;;
    *)                              echo "" ;;
  esac
}

# Where to obtain a value; printed by require_vars when it is missing.
how_to_get() {
  case "$1" in
    GRAFANA_OTLP_ENDPOINT|GRAFANA_INSTANCE_ID)
      echo "Grafana Cloud portal > your stack > OpenTelemetry > Configure (copy the OTLP endpoint and Instance ID)." ;;
    GRAFANA_CLOUD_APIKEY)
      echo "Grafana Cloud portal > Administration > Cloud access policies > Create access policy (realm: your stack; scopes metrics:write, logs:write, traces:write) > Add token." ;;
    GRAFANA_CLOUD_TOKEN)
      echo "Grafana Cloud portal > Administration > Cloud access policies > Create access policy (realm: your stack; scopes metrics:write, logs:write, traces:write, profiles:write) > Add token." ;;
    GRAFANA_FARO_ENDPOINT)
      echo "Grafana Cloud > Frontend Observability > Create new > copy the Collector URL." ;;
    GRAFANA_PYROSCOPE_*)
      echo "Grafana Cloud portal > your stack > Profiles > Details (URL, user and password/token)." ;;
    GRAFANA_CLOUD_METRICS_*|GRAFANA_CLOUD_LOGS_*|GRAFANA_CLOUD_PROFILES_*)
      echo "Grafana Cloud portal > your stack > Kubernetes > Start sending data (URL and username of each destination)." ;;
    DEMO_TARGET_URL)
      echo "The public URL of the shop reachable from Grafana Cloud, e.g. http://<load-balancer-or-public-ip>:8080." ;;
    *) echo "See docs/configuration.md." ;;
  esac
}

# Variable names defined in .env.example, in file order.
env_example_keys() {
  grep -E '^[A-Z][A-Z0-9_]*=' "${ENV_EXAMPLE}" | sed -E 's/=.*//'
}

# Reads KEY=value lines into the environment WITHOUT executing the file (so a
# token containing $ or & is safe, and "KEY= value" with a stray space works).
# Accepted: spaces around the value, an inline "  # comment", and one pair of
# surrounding single or double quotes (needed only for values with spaces). Lines that are not KEY=value are ignored.
parse_env_file() {
  local line key val rest
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      [A-Z]*=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    case "${key}" in *[!A-Z0-9_]*) continue ;; esac
    val="${line#*=}"
    # trim leading whitespace
    val="${val#"${val%%[![:space:]]*}"}"
    case "${val}" in
      \"*\"*) val="${val#\"}"; val="${val%%\"*}" ;;
      \'*\'*) val="${val#\'}"; val="${val%%\'*}" ;;
      *)
        # An unquoted value is its first word: none of these variables may
        # contain spaces. Anything after it is dropped (a comment is expected;
        # other text is reported, so a pasted-over line is noticed).
        rest="${val#"${val%%[[:space:]]*}"}"
        val="${val%%[[:space:]]*}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "${rest}" in
          ""|"#"*) ;;
          *) log_warn "${1##*/}: ignored extra text after the value of ${key} (put the value in quotes if it contains spaces)." ;;
        esac ;;
    esac
    export "${key}=${val}"
  done < "$1"
}

# Load .env.local without overriding variables already exported in the shell,
# then apply built-in defaults for everything that is still unset.
load_env() {
  [ -f "${ENV_EXAMPLE}" ] || die ".env.example not found at ${ENV_EXAMPLE}."
  local key shell_val file_val
  # Remember shell-provided values so they win over the file.
  for key in $(env_example_keys); do
    eval "shell_val=\"\${${key}:-}\""
    eval "__SHELL_${key}=\"\${shell_val}\""
  done
  if [ -f "${ENV_LOCAL}" ]; then
    parse_env_file "${ENV_LOCAL}"
  fi
  for key in $(env_example_keys); do
    eval "shell_val=\"\${__SHELL_${key}}\""
    eval "file_val=\"\${${key}:-}\""
    if ! is_unset "${shell_val}"; then
      eval "export ${key}=\"\${shell_val}\""
    elif ! is_unset "${file_val}"; then
      eval "export ${key}=\"\${file_val}\""
    else
      eval "export ${key}=\"\$(default_for ${key})\""
    fi
  done
}

# Stops with click-by-click remediation when any listed variable is unset.
# Re-running the script after fixing .env.local resumes where it stopped.
require_vars() {
  local missing=0 key val
  for key in "$@"; do
    eval "val=\"\${${key}:-}\""
    if is_unset "${val}"; then
      if [ "${missing}" -eq 0 ]; then
        log_error "Missing configuration. Edit ${ENV_LOCAL#"${REPO_ROOT}"/} and set:"
      fi
      missing=1
      log_error "  ${key}"
      log_error "      where to find it: $(how_to_get "${key}")"
    fi
  done
  if [ "${missing}" -ne 0 ]; then
    log_error ""
    log_error "If ${ENV_LOCAL#"${REPO_ROOT}"/} does not exist yet:  cp .env.example .env.local"
    log_error "Then run this script again; it continues from the first missing requirement."
    exit 1
  fi
}

# Region embedded in a Grafana Cloud access-policy token (glc_<base64 JSON>),
# e.g. "prod-us-east-0". Empty when it cannot be decoded. The secret part of the
# token is never read or printed.
token_region() {
  local b pad
  b="${1#glc_}"
  b="$(printf '%s' "${b}" | tr '_-' '/+')"
  pad=$(( (4 - ${#b} % 4) % 4 ))
  while [ "${pad}" -gt 0 ]; do b="${b}="; pad=$(( pad - 1 )); done
  { printf '%s' "${b}" | base64 -d 2>/dev/null || printf '%s' "${b}" | base64 -D 2>/dev/null; } \
    | LC_ALL=C sed -nE 's/.*"m":\{[^}]*"r":"([^"]+)".*/\1/p' | head -1
}

# check_grafana_cloud_credentials: verifies, before anything is deployed, that the
# OTLP credentials are accepted. Stops (exit 1) on a proven problem; only warns
# when it cannot tell (no network, unexpected answer). Skip: SKIP_CREDENTIAL_CHECK=true.
check_grafana_cloud_credentials() {
  [ "${SKIP_CREDENTIAL_CHECK:-false}" = "true" ] && { log_warn "Credential check skipped."; return 0; }
  local host region code
  host="$(printf '%s' "${GRAFANA_OTLP_ENDPOINT}" | sed -E 's#^https?://([^/]+).*#\1#')"
  region="$(token_region "${GRAFANA_CLOUD_APIKEY}")"
  if [ -n "${region}" ]; then
    case "${host}" in
      *"${region#prod-}"*) ;;
      *)
        log_error "The token belongs to region '${region}' but GRAFANA_OTLP_ENDPOINT points to '${host}'."
        log_error "Tokens only work for stacks in their own region (this is what makes Grafana answer HTTP 401)."
        log_error "Fix: in the Grafana Cloud portal open the stack that GRAFANA_OTLP_ENDPOINT and GRAFANA_INSTANCE_ID"
        log_error "come from > Administration > Cloud access policies > Create access policy for THAT stack's region"
        log_error "(scopes metrics:write, logs:write, traces:write) > Add token, and put it in GRAFANA_CLOUD_APIKEY."
        exit 1 ;;
    esac
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "curl not found; cannot test the credentials before deploying."
    return 0
  fi
  # Credentials travel through stdin (curl -K -), never on the command line.
  code="$(printf 'user = "%s:%s"\n' "${GRAFANA_INSTANCE_ID}" "${GRAFANA_CLOUD_APIKEY}" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
        -H 'Content-Type: application/json' -d '{}' "${GRAFANA_OTLP_ENDPOINT%/}/v1/traces" 2>/dev/null || true)"
  case "${code}" in
    401)
      log_error "Grafana Cloud rejected the credentials (HTTP 401) at ${host}."
      log_error "Check, in this order: 1) GRAFANA_INSTANCE_ID is the OTLP Instance ID of the same stack as the endpoint;"
      log_error "2) the token was created for that stack's region and has not been revoked or expired;"
      log_error "3) the token was copied completely (no cut-off, no extra characters)."
      exit 1 ;;
    403)
      log_error "The credentials are valid but lack permission (HTTP 403): add the scopes metrics:write, logs:write and traces:write."
      exit 1 ;;
    000|"")
      log_warn "Could not reach ${host} to test the credentials (no network?). Continuing." ;;
    2*|4*)
      log_ok "Grafana Cloud accepted the credentials (HTTP ${code})" ;;
    *)
      log_warn "Unexpected answer HTTP ${code} while testing the credentials. Continuing." ;;
  esac
}

# Preflight for the configuration file itself.
check_env_file() {
  if [ ! -f "${ENV_LOCAL}" ]; then
    log_warn ".env.local not found; creating it from .env.example."
    cp "${ENV_EXAMPLE}" "${ENV_LOCAL}"
    chmod 600 "${ENV_LOCAL}"
    log_warn "Created ${ENV_LOCAL#"${REPO_ROOT}"/} (gitignored). Fill in the values you need, then re-run."
  fi
  local key absent=0
  for key in $(env_example_keys); do
    if ! grep -qE "^${key}=" "${ENV_LOCAL}"; then
      [ "${absent}" -eq 0 ] && log_warn "Keys in .env.example that are absent from .env.local (defaults will be used):"
      absent=1
      log_warn "  ${key}"
    fi
  done
  return 0
}

# Writes the effective configuration for docker compose. "unknown"/empty values
# are omitted so containers never see the placeholder.
write_resolved_env() {
  mkdir -p "${BUILD_DIR}"
  ( umask 077; : > "${ENV_RESOLVED}" )
  local key val
  for key in $(env_example_keys); do
    eval "val=\"\${${key}:-}\""
    is_unset "${val}" && continue
    case "${val}" in
      *\'*) die "${key} contains a single quote, which cannot be written to an env file." ;;
    esac
    printf "%s='%s'\n" "${key}" "${val}" >> "${ENV_RESOLVED}"
  done
  chmod 600 "${ENV_RESOLVED}"
}

# docker compose env-file arguments, as the array COMPOSE_ENV_ARGS: upstream
# .env first, then .env.override, then the resolved workshop values.
build_compose_env_args() {
  COMPOSE_ENV_ARGS=( --env-file "${REPO_ROOT}/.env" )
  [ -f "${REPO_ROOT}/.env.override" ] && COMPOSE_ENV_ARGS+=( --env-file "${REPO_ROOT}/.env.override" )
  # Java workaround for Apple Silicon (macOS 15.2+, M4): JVMs crash without
  # -XX:UseSVE=0 (JDK-8345296). The upstream Makefile does the same.
  if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] && [ -f "${REPO_ROOT}/.env.arm64" ]; then
    COMPOSE_ENV_ARGS+=( --env-file "${REPO_ROOT}/.env.arm64" )
  fi
  [ -f "${ENV_RESOLVED}" ] && COMPOSE_ENV_ARGS+=( --env-file "${ENV_RESOLVED}" )
  return 0
}

# ── Templating ───────────────────────────────────────────────────────────────
# render_template SRC DST: replaces ${NAME} (NAME = [A-Z][A-Z0-9_]*) with the
# value of the environment variable. Unknown names are left untouched, so Grafana
# query syntax such as $__rate_interval is never altered. Uses perl, which is
# present on macOS and every common Linux (unlike envsubst).
render_template() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "${dst}")"
  perl -pe 's/\$\{([A-Z][A-Z0-9_]*)\}/(defined $ENV{$1} && $ENV{$1} ne "" && $ENV{$1} ne "unknown") ? $ENV{$1} : $&/ge' \
    "${src}" > "${dst}"
  local left
  left="$(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "${dst}" | sort -u | tr '\n' ' ' || true)"
  if [ -n "${left}" ]; then
    log_warn "$(basename "${dst}") still contains unresolved placeholders: ${left}"
    return 2
  fi
}

# ── Tooling checks ───────────────────────────────────────────────────────────
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "'${cmd}' is required but was not found."
    [ -n "${hint}" ] && log_error "  Install it: ${hint}"
    return 1
  fi
}

confirm() {
  # confirm "Question?"  -> 0 when the user answers y/Y, or when ASSUME_YES=true
  [ "${ASSUME_YES:-false}" = "true" ] && return 0
  local reply
  printf '%s [y/N] ' "$1"
  read -r reply
  [ "${reply}" = "y" ] || [ "${reply}" = "Y" ]
}
