#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# 1-click AWS deployment script for the OpenTelemetry Demo.
# Deploys the full demo on EKS using the official Helm chart.
#
# Usage:
#   ./scripts/deploy-aws.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME   EKS cluster name (default: EKS_CLUSTER_NAME, then otel-demo)
#   --region REGION       AWS region (default: AWS_REGION, then AWS_DEFAULT_REGION,
#                         then aws configure, then us-east-1)
#   --spot                Use Spot instances (~60% cheaper, may be interrupted)
#   --grafana-cloud       Send telemetry to Grafana Cloud and skip the local backends
#                         (Jaeger, Prometheus, Grafana, OpenSearch): fewer pods, cheaper.
#                         Needs GRAFANA_OTLP_ENDPOINT, GRAFANA_INSTANCE_ID and
#                         GRAFANA_CLOUD_APIKEY in .env.local.
#   --yes                 Skip confirmation prompts
#   --dry-run             Print what would be done without making changes
#   --destroy             Tear down all AWS resources (delegates to teardown-aws.sh)
#
# Configuration: sizing, tags, namespace and chart version come from .env.local
# (template .env.example): EKS_*, AWS_*, OTEL_DEMO_*. See docs/aws-deployment.md.
#
# Examples:
#   ./scripts/deploy-aws.sh
#   ./scripts/deploy-aws.sh --region eu-west-1 --spot
#   ./scripts/deploy-aws.sh --destroy

set -euo pipefail

# ============================================================
# Constants
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared helpers (configuration loading, templating). The logging functions
# below intentionally redefine the ones from common.sh to keep this script's
# output format.
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_env

# All values come from .env.local / the environment; see .env.example.
CLUSTER_NAME="${EKS_CLUSTER_NAME}"
K8S_VERSION="${EKS_K8S_VERSION}"
NODE_TYPE="${EKS_NODE_TYPE}"
NODE_COUNT="${EKS_NODE_COUNT}"
NODE_MIN="${EKS_NODE_MIN}"
NODE_MAX="${EKS_NODE_MAX}"
REGION="${AWS_REGION:-}"
USE_SPOT=false
GRAFANA_CLOUD_MODE=false
SKIP_CONFIRM=false
DRY_RUN=false
NAMESPACE="${OTEL_DEMO_NAMESPACE}"
HELM_RELEASE="${OTEL_DEMO_RELEASE}"
CHART_VERSION="${OTEL_DEMO_CHART_VERSION}"
LB_CONTROLLER_RELEASE="aws-load-balancer-controller"
TAG_KEY="${AWS_RESOURCE_TAG_KEY}"
TAG_VALUE="${AWS_RESOURCE_TAG_VALUE}"
RESOURCE_TAG="${TAG_KEY}=${TAG_VALUE}"

# Temp files (cleaned up on exit)
CLUSTER_CONFIG_FILE=""
VALUES_FILE=""

# ============================================================
# Color output
# ============================================================
if [ -t 1 ] && command -v tput &>/dev/null && tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${RESET}${BOLD} $*${RESET}"; }

# ============================================================
# Cleanup on exit
# ============================================================
cleanup() {
  [ -n "${CLUSTER_CONFIG_FILE:-}" ] && rm -f "$CLUSTER_CONFIG_FILE"
  [ -n "${VALUES_FILE:-}" ] && rm -f "$VALUES_FILE"
}
trap cleanup EXIT

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
      --region)       REGION="$2"; shift 2 ;;
      --spot)         USE_SPOT=true; shift ;;
      --grafana-cloud) GRAFANA_CLOUD_MODE=true; shift ;;
      --yes|-y)       SKIP_CONFIRM=true; shift ;;
      --dry-run)      DRY_RUN=true; shift ;;
      --destroy)
        exec "${SCRIPT_DIR}/teardown-aws.sh" "${@:2}"
        ;;
      --help|-h)
        grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        echo "Run '$0 --help' for usage."
        exit 1
        ;;
    esac
  done
}

# ============================================================
# Utility: version comparison (returns 0 if $1 >= $2)
# ============================================================
version_gte() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ============================================================
# Utility: detect package manager
# ============================================================
detect_pkg_manager() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then echo "brew"; else echo "none-mac"; fi
  elif command -v apt-get &>/dev/null; then echo "apt"
  elif command -v yum &>/dev/null; then echo "yum"
  elif command -v dnf &>/dev/null; then echo "dnf"
  else echo "none-linux"
  fi
}

# ============================================================
# Utility: install a tool
# ============================================================
try_install() {
  local tool="$1"
  local brew_pkg="${2:-$tool}"
  local apt_pkg="${3:-$tool}"
  local install_url="${4:-}"
  local pkg_mgr
  pkg_mgr="$(detect_pkg_manager)"

  log_info "Attempting to install ${tool}..."
  case "$pkg_mgr" in
    brew)
      brew install "$brew_pkg" 2>&1 | tail -5 ;;
    apt)
      sudo apt-get update -qq && sudo apt-get install -y "$apt_pkg" ;;
    yum)
      sudo yum install -y "$apt_pkg" ;;
    dnf)
      sudo dnf install -y "$apt_pkg" ;;
    none-mac)
      log_error "Homebrew is not installed. Install it first: https://brew.sh"
      [ -n "$install_url" ] && log_error "Or install ${tool} manually: ${install_url}"
      return 1
      ;;
    none-linux)
      log_error "No supported package manager found (apt/yum/dnf)."
      [ -n "$install_url" ] && log_error "Install ${tool} manually: ${install_url}"
      return 1
      ;;
  esac
}

# ============================================================
# Phase 1: Prerequisite verification
# ============================================================
phase_1_prerequisites() {
  log_step "Phase 1: Checking prerequisites"

  # ---- aws CLI ----
  local aws_ok=false
  if command -v aws &>/dev/null; then
    local aws_ver
    aws_ver="$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)"
    if version_gte "$aws_ver" "2.0.0" 2>/dev/null; then
      log_success "aws CLI ${aws_ver}"
      aws_ok=true
    else
      log_warn "aws CLI ${aws_ver} is too old (need v2+)"
    fi
  fi
  if ! $aws_ok; then
    log_warn "aws CLI not found or outdated. Attempting install..."
    if ! try_install "awscli" "awscli" "awscli" "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"; then
      log_error "Please install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      exit 1
    fi
    command -v aws &>/dev/null || { log_error "aws CLI install failed. See link above."; exit 1; }
    log_success "aws CLI installed"
  fi

  # ---- eksctl ----
  if ! command -v eksctl &>/dev/null; then
    log_warn "eksctl not found. Attempting install..."
    local pkg_mgr
    pkg_mgr="$(detect_pkg_manager)"
    if [[ "$pkg_mgr" == "brew" ]]; then
      brew tap weaveworks/tap 2>/dev/null || true
      brew install weaveworks/tap/eksctl
    else
      # Install from GitHub releases
      local eksctl_url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz"
      curl -sL "$eksctl_url" | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin/
    fi
    command -v eksctl &>/dev/null || { log_error "eksctl install failed. See: https://eksctl.io/installation/"; exit 1; }
  fi
  log_success "eksctl $(eksctl version 2>/dev/null | head -1)"

  # ---- kubectl ----
  if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl not found. Attempting install..."
    if ! try_install "kubectl" "kubernetes-cli" "kubectl" "https://kubernetes.io/docs/tasks/tools/"; then
      log_error "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"
      exit 1
    fi
    command -v kubectl &>/dev/null || { log_error "kubectl install failed."; exit 1; }
  fi
  log_success "kubectl $(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || kubectl version --client --short 2>/dev/null | head -1)"

  # ---- helm ----
  if ! command -v helm &>/dev/null; then
    log_warn "helm not found. Attempting install..."
    if ! try_install "helm" "helm" "helm" "https://helm.sh/docs/intro/install/"; then
      log_error "Please install Helm 3: https://helm.sh/docs/intro/install/"
      exit 1
    fi
    command -v helm &>/dev/null || { log_error "helm install failed."; exit 1; }
  fi
  log_success "helm $(helm version --short 2>/dev/null)"

  # ---- jq ----
  if ! command -v jq &>/dev/null; then
    log_warn "jq not found. Attempting install..."
    if ! try_install "jq" "jq" "jq" "https://jqlang.github.io/jq/download/"; then
      log_error "Please install jq: https://jqlang.github.io/jq/download/"
      exit 1
    fi
  fi
  log_success "jq $(jq --version 2>/dev/null)"

  log_success "All prerequisites satisfied."
}

# ============================================================
# Phase 2: AWS credentials + region
# ============================================================
phase_2_aws_validation() {
  log_step "Phase 2: Validating AWS credentials and region"

  # Resolve region
  if [ -z "$REGION" ]; then
    REGION="${AWS_DEFAULT_REGION:-}"
  fi
  if [ -z "$REGION" ]; then
    REGION="$(aws configure get region 2>/dev/null || true)"
  fi
  if [ -z "$REGION" ]; then
    log_warn "No AWS region configured. Defaulting to us-east-1."
    REGION="us-east-1"
  fi
  log_info "AWS region: ${REGION}"

  # Validate credentials
  local identity
  if ! identity="$(aws sts get-caller-identity --region "$REGION" --output json 2>&1)"; then
    log_error "AWS credentials are not configured or are invalid."
    echo ""
    echo -e "${YELLOW}AWS CLI error:${RESET}"
    echo "$identity"
    echo ""
    echo -e "${BOLD}How to configure AWS credentials:${RESET}"
    echo ""
    echo "  Option 1 — Interactive setup:"
    echo "    aws configure"
    echo "    (Enter your Access Key ID, Secret Access Key, region, and output format)"
    echo ""
    echo "  Option 2 — Environment variables:"
    echo "    export AWS_ACCESS_KEY_ID=<your-key>"
    echo "    export AWS_SECRET_ACCESS_KEY=<your-secret>"
    echo "    export AWS_SESSION_TOKEN=<token>   # if using temporary credentials"
    echo "    export AWS_DEFAULT_REGION=${REGION}"
    echo ""
    echo "  Option 3 — AWS SSO:"
    echo "    aws sso login"
    echo ""
    echo -e "${BOLD}Required IAM permissions:${RESET}"
    echo "  Your IAM user/role needs the following permissions:"
    echo "  - AmazonEKSClusterPolicy"
    echo "  - AmazonEKSWorkerNodePolicy"
    echo "  - AmazonEC2ContainerRegistryReadOnly"
    echo "  - AmazonVPCFullAccess (or specific VPC/subnet/SG permissions)"
    echo "  - elasticloadbalancing:* (for NLB provisioning)"
    echo "  - cloudformation:* (eksctl uses CloudFormation)"
    echo "  - iam:CreateRole, iam:AttachRolePolicy, iam:PassRole"
    echo "  - logs:CreateLogGroup, logs:DeleteLogGroup"
    echo ""
    echo "  See: https://eksctl.io/usage/minimum-iam-policies/"
    exit 2
  fi

  local account_id account_arn
  account_id="$(echo "$identity" | jq -r '.Account')"
  account_arn="$(echo "$identity" | jq -r '.Arn')"
  log_success "Authenticated as: ${account_arn} (account: ${account_id})"

  # Cost warning and confirmation
  local cost_estimate="~\$390/month"
  if $USE_SPOT; then
    cost_estimate="~\$130/month (Spot)"
  fi
  echo ""
  echo -e "${YELLOW}${BOLD}COST ESTIMATE${RESET}"
  echo -e "  EKS cluster '${CLUSTER_NAME}' in ${REGION}: ${BOLD}${cost_estimate}${RESET}"
  echo -e "  Components: EKS control plane + 2x ${NODE_TYPE} nodes + NLB + NAT Gateway"
  echo -e "  ${YELLOW}Run './scripts/teardown-aws.sh' when done to avoid ongoing charges.${RESET}"
  echo ""

  if ! $SKIP_CONFIRM && ! $DRY_RUN; then
    read -r -p "Proceed with deployment? [y/N] " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) log_info "Deployment cancelled."; exit 0 ;;
    esac
  fi
}

# ============================================================
# Helper: delete a single CloudFormation stack (handles termination protection)
# ============================================================
delete_orphan_stack() {
  local stack="$1"

  # Disable termination protection (eksctl enables it by default)
  aws cloudformation update-termination-protection \
    --stack-name "$stack" \
    --region "$REGION" \
    --no-enable-termination-protection &>/dev/null || true

  log_info "Deleting orphan stack '${stack}'..."
  if ! aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"; then
    log_error "Failed to initiate delete on '${stack}'. Manual cleanup required via CloudFormation console."
    return 1
  fi

  log_info "Waiting for '${stack}' deletion to complete..."
  if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"; then
    log_success "Orphan stack '${stack}' deleted."
    return 0
  else
    log_error "Failed to delete '${stack}'. Manual cleanup required via CloudFormation console."
    return 1
  fi
}

# ============================================================
# Helper: detect and clean up orphan eksctl CloudFormation stacks
# ============================================================
# An "orphan" stack is one that has the eksctl-${CLUSTER_NAME}-* naming prefix
# but no corresponding live EKS cluster — typically left behind by a prior run
# that failed mid-create. Such stacks (in ROLLBACK_COMPLETE / CREATE_FAILED /
# DELETE_FAILED / ROLLBACK_FAILED) block CreateStack with AlreadyExistsException
# even though they hold no live AWS resources.
clean_orphan_stacks() {
  local cluster_stack="eksctl-${CLUSTER_NAME}-cluster"
  local stacks
  stacks="$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter CREATE_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED \
                          ROLLBACK_IN_PROGRESS DELETE_FAILED \
    --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-')].StackName" \
    --output text 2>/dev/null || true)"

  if [ -z "$stacks" ]; then
    return 0
  fi

  log_warn "Found orphan CloudFormation stack(s) from a prior failed run:"
  for stack in $stacks; do
    log_warn "  - ${stack}"
  done
  log_info "Cleaning these up before creating the new cluster (safe — they hold no live resources)."

  # Delete nodegroup stacks first (they may reference the cluster stack)
  for stack in $stacks; do
    [[ "$stack" == "$cluster_stack" ]] && continue
    delete_orphan_stack "$stack" || exit 1
  done

  # Then delete the cluster stack
  for stack in $stacks; do
    [[ "$stack" != "$cluster_stack" ]] && continue
    delete_orphan_stack "$stack" || exit 1
  done
}

# ============================================================
# Phase 3: EKS cluster provisioning
# ============================================================
phase_3_provision_cluster() {
  log_step "Phase 3: EKS cluster provisioning"

  # Always sweep orphan eksctl-${CLUSTER_NAME}-* stacks first (in failed/rollback
  # states). These can block any subsequent CreateStack — for the cluster itself,
  # for nodegroups, for addons, and for iamserviceaccount roles. Safe to run
  # whether or not a live cluster exists, since ROLLBACK_COMPLETE stacks hold
  # no live resources by definition.
  if ! $DRY_RUN; then
    clean_orphan_stacks
  fi

  # Check if cluster already exists
  if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null 2>&1; then
    log_success "Cluster '${CLUSTER_NAME}' already exists in ${REGION}. Skipping creation."
    # Update kubeconfig
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
    return 0
  fi

  log_info "Creating EKS cluster '${CLUSTER_NAME}' in ${REGION} (this takes ~15 minutes)..."

  CLUSTER_CONFIG_FILE="$(mktemp /tmp/otel-demo-cluster.XXXXXX.yaml)"
  local capacity_type="ON_DEMAND"
  $USE_SPOT && capacity_type="SPOT"

  cat > "$CLUSTER_CONFIG_FILE" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
  tags:
    ${TAG_KEY}: ${TAG_VALUE}

iam:
  withOIDC: true

managedNodeGroups:
  - name: otel-demo-nodes
    instanceType: ${NODE_TYPE}
    desiredCapacity: ${NODE_COUNT}
    minSize: ${NODE_MIN}
    maxSize: ${NODE_MAX}
    tags:
      ${TAG_KEY}: ${TAG_VALUE}
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
EOF

  if $DRY_RUN; then
    log_info "[DRY RUN] Would create cluster with config:"
    cat "$CLUSTER_CONFIG_FILE"
    return 0
  fi

  eksctl create cluster -f "$CLUSTER_CONFIG_FILE"
  log_success "Cluster '${CLUSTER_NAME}' created."
}

# ============================================================
# Phase 4: Kubernetes prerequisites
# ============================================================
phase_4_k8s_prerequisites() {
  log_step "Phase 4: Installing Kubernetes prerequisites"

  # ---- metrics-server ----
  if ! kubectl get deployment metrics-server -n kube-system &>/dev/null 2>&1; then
    log_info "Installing metrics-server..."
    if ! $DRY_RUN; then
      kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    fi
  else
    log_success "metrics-server already installed."
  fi

  # ---- AWS Load Balancer Controller ----
  if helm status "$LB_CONTROLLER_RELEASE" -n kube-system &>/dev/null 2>&1; then
    log_success "AWS Load Balancer Controller already installed."
    return 0
  fi

  log_info "Creating IAM service account for AWS Load Balancer Controller..."
  if ! $DRY_RUN; then
    # Pin to a known-good upstream IAM policy version. Bump this in tandem
    # with the LB Controller helm chart version below — they must match,
    # or you'll see AccessDenied on newer ELBv2 API actions
    # (e.g. DescribeListenerAttributes).
    local lb_iam_policy_version="v2.13.0"
    local lb_policy_url="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${lb_iam_policy_version}/docs/install/iam_policy.json"
    local lb_policy_file="/tmp/aws-lb-iam-policy-${lb_iam_policy_version}.json"

    if ! curl -fsSL -o "$lb_policy_file" "$lb_policy_url"; then
      log_error "Failed to download IAM policy from ${lb_policy_url}"
      return 1
    fi

    local aws_account_id
    aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
    local policy_arn="arn:aws:iam::${aws_account_id}:policy/AWSLoadBalancerControllerIAMPolicy"

    if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null 2>&1; then
      log_info "IAM policy 'AWSLoadBalancerControllerIAMPolicy' already exists; ensuring it is up to date."

      # IAM caps each policy at 5 versions. If we are at the cap, delete the
      # oldest non-default version before creating the new one.
      local versions_json
      versions_json="$(aws iam list-policy-versions --policy-arn "$policy_arn" \
        --query "Versions[?IsDefaultVersion==\`false\`].[VersionId,CreateDate]" \
        --output text 2>/dev/null || true)"
      local version_count
      version_count="$(echo "$versions_json" | grep -c .)"
      if [ "$version_count" -ge 4 ]; then
        local oldest_version
        oldest_version="$(echo "$versions_json" | sort -k2 | head -1 | awk '{print $1}')"
        if [ -n "$oldest_version" ]; then
          log_info "Pruning oldest non-default policy version ${oldest_version} to make room."
          aws iam delete-policy-version \
            --policy-arn "$policy_arn" \
            --version-id "$oldest_version" 2>/dev/null || true
        fi
      fi

      # Create the new version and set as default. Capture stderr so we can
      # surface real errors instead of silently swallowing them.
      local create_err
      if create_err="$(aws iam create-policy-version \
        --policy-arn "$policy_arn" \
        --policy-document "file://$lb_policy_file" \
        --set-as-default 2>&1 >/dev/null)"; then
        log_success "IAM policy upgraded to ${lb_iam_policy_version}."
      elif echo "$create_err" | grep -q "MalformedPolicyDocument\|already the default"; then
        log_info "Policy already at the requested content; nothing to do."
      else
        log_warn "Could not upgrade IAM policy: ${create_err}"
        log_warn "Continuing — existing policy will be used (may be missing newer permissions)."
      fi
    else
      if aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document "file://$lb_policy_file" \
        --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" &>/dev/null; then
        log_success "IAM policy created (${lb_iam_policy_version})."
      else
        log_error "Failed to create IAM policy 'AWSLoadBalancerControllerIAMPolicy'."
        return 1
      fi
    fi
    rm -f "$lb_policy_file"

    # IAM roles are account-global. Suffix with cluster name + region so multiple
    # demo clusters in the same AWS account don't collide on this role name.
    local lb_role_name="AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME}-${REGION}"

    eksctl create iamserviceaccount \
      --cluster="$CLUSTER_NAME" \
      --namespace=kube-system \
      --name=aws-load-balancer-controller \
      --role-name "$lb_role_name" \
      --attach-policy-arn="arn:aws:iam::${aws_account_id}:policy/AWSLoadBalancerControllerIAMPolicy" \
      --region="$REGION" \
      --override-existing-serviceaccounts \
      --approve
  fi

  log_info "Installing AWS Load Balancer Controller..."
  if ! $DRY_RUN; then
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update eks

    local vpc_id
    vpc_id="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
      --query "cluster.resourcesVpcConfig.vpcId" --output text)"

    helm install "$LB_CONTROLLER_RELEASE" eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName="$CLUSTER_NAME" \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region="$REGION" \
      --set vpcId="$vpc_id" \
      --wait --timeout 5m
  fi

  log_success "AWS Load Balancer Controller installed."
}

# ============================================================
# Phase 5: Helm deploy
# ============================================================
phase_5_deploy() {
  log_step "Phase 5: Deploying OpenTelemetry Demo via Helm"

  # NOTE on the values key name: the upstream opentelemetry-demo chart renamed
  # 'components.frontendProxy' to 'components.frontend-proxy' (kebab-case) in
  # newer chart versions. The schema rejects the old name. Keep this in sync
  # with `helm show values open-telemetry/opentelemetry-demo`.
  VALUES_FILE="$(mktemp /tmp/otel-demo-values.XXXXXX.yaml)"
  cat > "$VALUES_FILE" <<EOF
components:
  frontend-proxy:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
        tags: "${RESOURCE_TAG}"
EOF

  # Grafana Cloud mode: no local backends, collector exports to Grafana Cloud.
  # The credentials are put into a Kubernetes secret, never into a values file.
  local extra_values=()
  if $GRAFANA_CLOUD_MODE; then
    require_vars GRAFANA_OTLP_ENDPOINT GRAFANA_INSTANCE_ID GRAFANA_CLOUD_APIKEY
    extra_values=( --values "${REPO_ROOT}/kubernetes/values-grafana-cloud.yaml" )
    if ! $DRY_RUN; then
      local secret_file
      mkdir -p "${BUILD_DIR}"
      secret_file="$(mktemp "${BUILD_DIR}/aws-secret.XXXXXX")"
      chmod 600 "$secret_file"
      printf 'GRAFANA_OTLP_ENDPOINT=%s\nGRAFANA_INSTANCE_ID=%s\nGRAFANA_CLOUD_APIKEY=%s\n' \
        "$GRAFANA_OTLP_ENDPOINT" "$GRAFANA_INSTANCE_ID" "$GRAFANA_CLOUD_APIKEY" > "$secret_file"
      kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      kubectl -n "$NAMESPACE" create secret generic grafana-cloud-otlp --from-env-file="$secret_file" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      rm -f "$secret_file"
      log_success "Secret grafana-cloud-otlp applied to namespace ${NAMESPACE}."
    fi
  fi

  if ! $DRY_RUN; then
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
    helm repo update open-telemetry

    helm upgrade --install "$HELM_RELEASE" open-telemetry/opentelemetry-demo \
      --version "$CHART_VERSION" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      --wait \
      --timeout 15m \
      --values "$VALUES_FILE" \
      ${extra_values[@]+"${extra_values[@]}"}
  else
    log_info "[DRY RUN] Would deploy chart opentelemetry-demo ${CHART_VERSION} with values:"
    cat "$VALUES_FILE"
    $GRAFANA_CLOUD_MODE && log_info "[DRY RUN] plus kubernetes/values-grafana-cloud.yaml and the grafana-cloud-otlp secret."
  fi

  log_success "OpenTelemetry Demo deployed."
}

# ============================================================
# Phase 6: Get URL
# ============================================================
phase_6_get_url() {
  log_step "Phase 6: Retrieving service URL"

  # Resolve the actual frontend-proxy service name. The upstream chart's
  # naming has drifted across versions:
  #   * older: components.frontendProxy → service '<release>-frontendproxy'
  #   * mid:   components.frontend-proxy → service '<release>-frontend-proxy'
  #   * current: components.frontend-proxy → service 'frontend-proxy' (no release prefix)
  # Try all three so this works against any chart version.
  local svc_name=""
  for candidate in "frontend-proxy" \
                   "${HELM_RELEASE}-frontend-proxy" \
                   "${HELM_RELEASE}-frontendproxy"; do
    if kubectl get service "$candidate" -n "$NAMESPACE" &>/dev/null; then
      svc_name="$candidate"
      break
    fi
  done

  if $DRY_RUN; then
    log_info "[DRY RUN] Would poll for NLB hostname on the frontend-proxy service in namespace '${NAMESPACE}'."
    return 0
  fi

  if [ -z "$svc_name" ]; then
    log_error "Could not find a frontend-proxy service in namespace '${NAMESPACE}'."
    log_error "Available services:"
    kubectl get services -n "$NAMESPACE" 2>&1 | sed 's/^/  /'
    return 1
  fi

  log_info "Found frontend-proxy service: ${svc_name}"
  log_info "Waiting for NLB hostname (up to 3 minutes)..."
  local hostname=""
  local attempts=0
  local max_attempts=18  # 18 * 10s = 3 minutes

  while [ $attempts -lt $max_attempts ]; do
    hostname="$(kubectl get service "$svc_name" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [ -n "$hostname" ]; then
      break
    fi
    attempts=$((attempts + 1))
    log_info "Waiting for NLB hostname... (${attempts}/${max_attempts})"
    sleep 10
  done

  if [ -z "$hostname" ]; then
    log_warn "Could not retrieve NLB hostname after 3 minutes."
    log_warn "Check status with: kubectl get service ${svc_name} -n ${NAMESPACE}"
    return 0
  fi

  local cost_label="~\$390/month"
  $USE_SPOT && cost_label="~\$130/month (Spot)"

  echo ""
  echo -e "${GREEN}${BOLD}=================================================${RESET}"
  echo -e "${GREEN}${BOLD}  OpenTelemetry Demo is LIVE on AWS!${RESET}"
  echo -e "${GREEN}${BOLD}=================================================${RESET}"
  echo -e "  Frontend:    ${CYAN}http://${hostname}:8080${RESET}"
  if $GRAFANA_CLOUD_MODE; then
    echo -e "  Telemetry:   sent to Grafana Cloud (no local Grafana or Jaeger)"
  else
    echo -e "  Grafana:     ${CYAN}http://${hostname}:8080/grafana/${RESET}"
    echo -e "  Jaeger:      ${CYAN}http://${hostname}:8080/jaeger/ui${RESET}"
  fi
  echo -e "  Load Gen:    ${CYAN}http://${hostname}:8080/loadgen/${RESET}"
  echo -e "${GREEN}${BOLD}=================================================${RESET}"
  echo -e "  Teardown:    ${YELLOW}./scripts/teardown-aws.sh${RESET}"
  echo -e "  Cost est:    ${YELLOW}${cost_label}${RESET}"
  echo -e "${GREEN}${BOLD}=================================================${RESET}"
  echo ""
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  check_env_file

  echo ""
  echo -e "${BOLD}OpenTelemetry Demo — AWS Deployment${RESET}"
  echo -e "Cluster: ${CYAN}${CLUSTER_NAME}${RESET}  |  Node type: ${CYAN}${NODE_TYPE} x${NODE_COUNT}${RESET}  |  Spot: ${CYAN}${USE_SPOT}${RESET}"
  echo ""

  phase_1_prerequisites
  phase_2_aws_validation
  phase_3_provision_cluster
  phase_4_k8s_prerequisites
  phase_5_deploy
  phase_6_get_url
}

main "$@"
