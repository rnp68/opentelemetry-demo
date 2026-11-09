#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Comprehensive AWS teardown script for the OpenTelemetry Demo.
# Removes ALL AWS resources in the correct order to prevent orphaning,
# then runs a tag-based sweep to verify nothing is left.
#
# Resources deleted (in order):
#   1. Helm release: opentelemetry-demo (triggers NLB decommission)
#   2. Wait for NLB full decommission
#   3. Orphaned EBS Persistent Volumes
#   4. Helm release: aws-load-balancer-controller
#   5. Kubernetes namespace: otel-demo
#   6. IAM service account (IRSA) for LB Controller
#   7. EKS cluster (VPC, subnets, SGs, NAT GW, IAM roles, CloudFormation stacks)
#   8. CloudWatch log groups
#   9. IAM policy: AWSLoadBalancerControllerIAMPolicy
#  10. Final tag sweep verification (cross-checks each ARN against its real
#      state to filter out tombstones the Resource Groups Tagging API still
#      reports for up to ~1 hour after deletion)
#
# Usage:
#   ./scripts/teardown-aws.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME   EKS cluster name (default: EKS_CLUSTER_NAME, then otel-demo)
#   --region REGION       AWS region (default: AWS_REGION, then AWS_DEFAULT_REGION,
#                         then aws configure, then us-east-1)
#   --yes                 Skip confirmation prompt
#
# Configuration comes from .env.local (template .env.example): EKS_CLUSTER_NAME,
# AWS_REGION, AWS_RESOURCE_TAG_KEY/VALUE, OTEL_DEMO_NAMESPACE, OTEL_DEMO_RELEASE.
# The tag values must match the ones used by deploy-aws.sh.

set -euo pipefail

# ============================================================
# Constants
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_env

CLUSTER_NAME="${EKS_CLUSTER_NAME}"
REGION="${AWS_REGION:-}"
SKIP_CONFIRM=false
NAMESPACE="${OTEL_DEMO_NAMESPACE}"
HELM_RELEASE="${OTEL_DEMO_RELEASE}"
LB_CONTROLLER_RELEASE="aws-load-balancer-controller"
TAG_KEY="${AWS_RESOURCE_TAG_KEY}"
TAG_VALUE="${AWS_RESOURCE_TAG_VALUE}"

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
log_success() { echo -e "${GREEN}[✓]${RESET}     $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}Step $*${RESET}"; }

DELETED_ITEMS=()
FAILED_ITEMS=()

mark_deleted() { DELETED_ITEMS+=("$1"); }
mark_failed()  { FAILED_ITEMS+=("$1"); }

# ============================================================
# Helper: delete a single CloudFormation stack (handles termination protection)
# ============================================================
teardown_delete_orphan_stack() {
  local stack="$1"

  # Disable termination protection (eksctl enables it by default)
  aws cloudformation update-termination-protection \
    --stack-name "$stack" \
    --region "$REGION" \
    --no-enable-termination-protection &>/dev/null || true

  log_info "Deleting orphan stack '${stack}'..."
  if ! aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"; then
    log_error "Failed to initiate delete on '${stack}'."
    return 1
  fi

  log_info "Waiting for '${stack}' deletion to complete..."
  if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"; then
    log_success "Orphan stack '${stack}' deleted."
    return 0
  else
    log_error "Failed to delete '${stack}'. Check CloudFormation console."
    return 1
  fi
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
      --region)       REGION="$2"; shift 2 ;;
      --yes|-y)       SKIP_CONFIRM=true; shift ;;
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
# Step 1: Validate credentials + confirm
# ============================================================
step_1_validate() {
  log_step "1 — Validating AWS credentials"

  # Resolve region
  if [ -z "$REGION" ]; then
    REGION="${AWS_DEFAULT_REGION:-}"
  fi
  if [ -z "$REGION" ]; then
    REGION="$(aws configure get region 2>/dev/null || true)"
  fi
  if [ -z "$REGION" ]; then
    REGION="us-east-1"
    log_warn "No AWS region configured. Defaulting to us-east-1."
  fi
  log_info "AWS region: ${REGION}"

  local identity
  if ! identity="$(aws sts get-caller-identity --region "$REGION" --output json 2>&1)"; then
    log_error "AWS credentials are not configured or are invalid:"
    echo "$identity"
    echo ""
    echo "Configure credentials with one of:"
    echo "  aws configure"
    echo "  export AWS_ACCESS_KEY_ID=... && export AWS_SECRET_ACCESS_KEY=..."
    echo "  aws sso login"
    exit 2
  fi

  local account_arn
  account_arn="$(echo "$identity" | jq -r '.Arn')"
  log_success "Authenticated as: ${account_arn}"

  # Check if cluster exists
  if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null 2>&1; then
    log_warn "Cluster '${CLUSTER_NAME}' not found in ${REGION}."

    # The live cluster may be gone, but orphan eksctl-${CLUSTER_NAME}-* CFN stacks
    # can still be lying around (e.g. ROLLBACK_COMPLETE from a failed CreateStack)
    # and blocking future deploys. Detect and clean them up before bailing.
    local orphan_stacks
    orphan_stacks="$(aws cloudformation list-stacks \
      --region "$REGION" \
      --stack-status-filter CREATE_COMPLETE CREATE_FAILED \
                            ROLLBACK_COMPLETE ROLLBACK_FAILED \
                            ROLLBACK_IN_PROGRESS DELETE_FAILED \
                            UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-')].StackName" \
      --output text 2>/dev/null || true)"

    if [ -n "$orphan_stacks" ]; then
      log_warn "Found orphan CloudFormation stack(s) for cluster '${CLUSTER_NAME}':"
      for stack in $orphan_stacks; do
        log_warn "  - ${stack}"
      done
      log_info "Cleaning these up..."

      local cluster_stack="eksctl-${CLUSTER_NAME}-cluster"

      # Delete nodegroup stacks first (they may reference the cluster stack)
      for stack in $orphan_stacks; do
        [[ "$stack" == "$cluster_stack" ]] && continue
        teardown_delete_orphan_stack "$stack" || mark_failed "Orphan stack: ${stack}"
      done

      # Then delete the cluster stack
      for stack in $orphan_stacks; do
        [[ "$stack" != "$cluster_stack" ]] && continue
        teardown_delete_orphan_stack "$stack" || mark_failed "Orphan stack: ${stack}"
      done
      mark_deleted "Orphan CloudFormation stacks for ${CLUSTER_NAME}"
    else
      log_info "No orphan CloudFormation stacks found either."
    fi

    log_info "Running final tag sweep to check for any other orphaned resources..."
    step_10_tag_sweep
    exit 0
  fi
  log_success "Found EKS cluster: ${CLUSTER_NAME}"

  # Safety gate
  if ! $SKIP_CONFIRM; then
    echo ""
    echo -e "${RED}${BOLD}WARNING: DESTRUCTIVE OPERATION${RESET}"
    echo ""
    echo "This will PERMANENTLY DELETE:"
    echo "  - EKS cluster '${CLUSTER_NAME}' in ${REGION}"
    echo "  - All worker nodes (EC2 instances)"
    echo "  - All Kubernetes workloads and data"
    echo "  - Network Load Balancer"
    echo "  - VPC, subnets, security groups, NAT gateway, internet gateway"
    echo "  - IAM roles and policies for this cluster"
    echo "  - CloudWatch log groups: /aws/eks/${CLUSTER_NAME}/*"
    echo ""
    echo -e "To confirm, type the cluster name: ${BOLD}${CLUSTER_NAME}${RESET}"
    read -r confirm_name
    if [ "$confirm_name" != "$CLUSTER_NAME" ]; then
      log_info "Cluster name did not match. Teardown cancelled."
      exit 0
    fi
  fi
}

# ============================================================
# Step 2: Uninstall Helm release (triggers NLB decommission)
# ============================================================
step_2_uninstall_demo() {
  log_step "2 — Uninstalling Helm release: ${HELM_RELEASE}"

  if ! helm status "$HELM_RELEASE" -n "$NAMESPACE" &>/dev/null 2>&1; then
    log_info "Helm release '${HELM_RELEASE}' not found. Skipping."
    return 0
  fi

  log_info "Uninstalling '${HELM_RELEASE}' (this triggers NLB deletion via LB Controller)..."
  if helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" --wait --timeout 10m; then
    log_success "Helm release '${HELM_RELEASE}' uninstalled."
    mark_deleted "Helm release: ${HELM_RELEASE}"
  else
    log_warn "Helm uninstall had errors. Continuing..."
    mark_failed "Helm release: ${HELM_RELEASE} (partial)"
  fi
}

# ============================================================
# Step 3: Wait for NLB decommission
# ============================================================
step_3_wait_nlb() {
  log_step "3 — Waiting for Network Load Balancer decommission"

  # Get the VPC ID for this cluster
  local vpc_id
  vpc_id="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)"

  if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    log_info "Could not determine VPC ID. Skipping NLB wait."
    return 0
  fi

  log_info "Checking for NLBs in VPC ${vpc_id}..."
  local attempts=0
  local max_attempts=30  # 30 * 10s = 5 minutes

  while [ $attempts -lt $max_attempts ]; do
    local lb_count
    lb_count="$(aws elbv2 describe-load-balancers \
      --region "$REGION" \
      --query "LoadBalancers[?VpcId=='${vpc_id}'] | length(@)" \
      --output text 2>/dev/null || echo "0")"

    if [ "$lb_count" = "0" ] || [ -z "$lb_count" ]; then
      log_success "No load balancers remaining in VPC ${vpc_id}."
      mark_deleted "Network Load Balancer"
      return 0
    fi

    attempts=$((attempts + 1))
    log_info "Waiting for ${lb_count} load balancer(s) to decommission... (${attempts}/${max_attempts})"
    sleep 10
  done

  log_warn "Load balancers may still exist after 5 minutes. Check manually:"
  log_warn "  aws elbv2 describe-load-balancers --region ${REGION} --query \"LoadBalancers[?VpcId=='${vpc_id}']\" --output table"
  mark_failed "Network Load Balancer (may still exist)"
}

# ============================================================
# Step 4: Delete EBS Persistent Volumes
# ============================================================
step_4_delete_pvcs() {
  log_step "4 — Deleting Persistent Volume Claims"

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null 2>&1; then
    log_info "Namespace '${NAMESPACE}' not found. Skipping PVC deletion."
    return 0
  fi

  local pvc_count
  pvc_count="$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [ "$pvc_count" = "0" ]; then
    log_info "No PVCs found in namespace '${NAMESPACE}'."
    return 0
  fi

  log_info "Deleting ${pvc_count} PVC(s) in namespace '${NAMESPACE}'..."
  kubectl delete pvc --all -n "$NAMESPACE" --wait=true --timeout=3m 2>/dev/null || \
    log_warn "Some PVCs may not have been deleted cleanly."

  # Verify EBS volumes are gone
  local ebs_count
  ebs_count="$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=status,Values=available,in-use" \
    --query "Volumes | length(@)" \
    --output text 2>/dev/null || echo "0")"

  if [ "$ebs_count" = "0" ] || [ -z "$ebs_count" ]; then
    log_success "EBS volumes deleted."
    mark_deleted "EBS Persistent Volumes (${pvc_count} PVCs)"
  else
    log_warn "${ebs_count} EBS volume(s) may still exist."
    mark_failed "EBS volumes (${ebs_count} remaining)"
  fi
}

# ============================================================
# Step 5: Uninstall AWS Load Balancer Controller
# ============================================================
step_5_uninstall_lb_controller() {
  log_step "5 — Uninstalling AWS Load Balancer Controller"

  if ! helm status "$LB_CONTROLLER_RELEASE" -n kube-system &>/dev/null 2>&1; then
    log_info "AWS Load Balancer Controller not found. Skipping."
    return 0
  fi

  if helm uninstall "$LB_CONTROLLER_RELEASE" -n kube-system --wait --timeout 5m; then
    log_success "AWS Load Balancer Controller uninstalled."
    mark_deleted "Helm release: ${LB_CONTROLLER_RELEASE}"
  else
    log_warn "LB Controller uninstall had errors."
    mark_failed "Helm release: ${LB_CONTROLLER_RELEASE}"
  fi
}

# ============================================================
# Step 6: Delete namespace
# ============================================================
step_6_delete_namespace() {
  log_step "6 — Deleting Kubernetes namespace: ${NAMESPACE}"

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null 2>&1; then
    log_info "Namespace '${NAMESPACE}' not found. Skipping."
    return 0
  fi

  if kubectl delete namespace "$NAMESPACE" --wait=true --timeout=5m 2>/dev/null; then
    log_success "Namespace '${NAMESPACE}' deleted."
    mark_deleted "Kubernetes namespace: ${NAMESPACE}"
  else
    log_warn "Namespace deletion may have timed out. Resources with finalizers may remain."
    mark_failed "Kubernetes namespace: ${NAMESPACE}"
  fi
}

# ============================================================
# Step 7: Delete IAM service accounts (IRSA)
# ============================================================
step_7_delete_iam_serviceaccount() {
  log_step "7 — Deleting IAM service account for Load Balancer Controller"

  # Check if eksctl can find the iamserviceaccount
  if eksctl get iamserviceaccount \
    --cluster="$CLUSTER_NAME" \
    --region="$REGION" \
    --name=aws-load-balancer-controller \
    --namespace=kube-system 2>/dev/null | grep -q "aws-load-balancer-controller"; then

    if eksctl delete iamserviceaccount \
      --cluster="$CLUSTER_NAME" \
      --region="$REGION" \
      --name=aws-load-balancer-controller \
      --namespace=kube-system \
      --wait 2>/dev/null; then
      log_success "IAM service account deleted."
      mark_deleted "IAM service account: aws-load-balancer-controller"
    else
      log_warn "IAM service account deletion failed. May require manual cleanup."
      mark_failed "IAM service account: aws-load-balancer-controller"
    fi
  else
    log_info "IAM service account not found or already deleted."
  fi
}

# ============================================================
# Step 8: Delete EKS cluster
# ============================================================
step_8_delete_cluster() {
  log_step "8 — Deleting EKS cluster: ${CLUSTER_NAME}"
  log_info "This deletes: cluster, node groups, VPC, subnets, security groups,"
  log_info "NAT gateway, internet gateway, route tables, IAM roles."
  log_info "This takes ~10-15 minutes..."

  if eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait; then
    log_success "EKS cluster '${CLUSTER_NAME}' deleted (VPC and all associated resources)."
    mark_deleted "EKS cluster: ${CLUSTER_NAME} (+ VPC, subnets, SGs, NAT GW, IAM roles)"
  else
    log_error "Cluster deletion failed or timed out."
    log_error "Check CloudFormation stacks in ${REGION} for cleanup status."
    mark_failed "EKS cluster: ${CLUSTER_NAME}"
  fi
}

# ============================================================
# Step 9: Delete CloudWatch log groups
# ============================================================
step_9_delete_log_groups() {
  log_step "9 — Deleting CloudWatch log groups"

  local log_groups
  log_groups="$(aws logs describe-log-groups \
    --region "$REGION" \
    --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" \
    --query "logGroups[*].logGroupName" \
    --output text 2>/dev/null || true)"

  if [ -z "$log_groups" ]; then
    log_info "No CloudWatch log groups found for cluster '${CLUSTER_NAME}'."
    return 0
  fi

  local deleted_count=0
  while IFS= read -r lg; do
    [ -z "$lg" ] && continue
    if aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null; then
      log_success "Deleted log group: ${lg}"
      deleted_count=$((deleted_count + 1))
    else
      log_warn "Could not delete log group: ${lg}"
      mark_failed "CloudWatch log group: ${lg}"
    fi
  done <<< "$log_groups"

  if [ $deleted_count -gt 0 ]; then
    mark_deleted "CloudWatch log groups: /aws/eks/${CLUSTER_NAME}/* (${deleted_count} groups)"
  fi
}

# ============================================================
# Step 9b: Delete IAM policy
# ============================================================
step_9b_delete_iam_policy() {
  log_step "9b — Deleting IAM policy: AWSLoadBalancerControllerIAMPolicy"

  local aws_account_id
  aws_account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"

  if [ -z "$aws_account_id" ]; then
    log_warn "Could not get AWS account ID. Skipping IAM policy deletion."
    return 0
  fi

  local policy_arn="arn:aws:iam::${aws_account_id}:policy/AWSLoadBalancerControllerIAMPolicy"

  if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null 2>&1; then
    # The IAM policy is shared by name across any deploy of this demo. Detach
    # ONLY our cluster's role from it — never detach roles belonging to other
    # clusters, or those clusters' LB controllers will silently break.
    local our_role_name="AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME}-${REGION}"
    aws iam detach-role-policy \
      --role-name "$our_role_name" \
      --policy-arn "$policy_arn" 2>/dev/null || true

    # Check if any other roles still reference this policy
    local remaining_roles
    remaining_roles="$(aws iam list-entities-for-policy \
      --policy-arn "$policy_arn" \
      --entity-filter Role \
      --query "PolicyRoles[*].RoleName" \
      --output text 2>/dev/null || true)"

    if [ -n "$remaining_roles" ]; then
      log_warn "IAM policy 'AWSLoadBalancerControllerIAMPolicy' is still in use by other roles:"
      for role in $remaining_roles; do
        [ -z "$role" ] && continue
        log_warn "  - ${role}"
      done
      log_info "Leaving the shared policy in place to avoid breaking other clusters."
      log_info "(This policy is account-global and intentionally shared across demo deploys.)"
    else
      if aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null; then
        log_success "IAM policy deleted: AWSLoadBalancerControllerIAMPolicy (no other roles using it)"
        mark_deleted "IAM policy: AWSLoadBalancerControllerIAMPolicy"
      else
        log_warn "Could not delete IAM policy. Check for residual attachments."
        mark_failed "IAM policy: AWSLoadBalancerControllerIAMPolicy"
      fi
    fi
  else
    log_info "IAM policy not found or already deleted."
  fi
}

# ============================================================
# Helper: classify a tagged ARN against the resource's real state.
#
# The Resource Groups Tagging API has up to ~1 hour of propagation lag, and
# the EC2 describe-* APIs keep tombstones (terminated instances, deleted NAT
# gateways) visible for the same window. Both effects cause the tag sweep to
# return ARNs for resources that are already gone. Classifying each ARN
# against its real state lets us tell apart genuinely-orphaned resources
# from stale tag-sweep entries.
#
# Returns:
#   0 = alive       (resource still exists; needs manual cleanup)
#   1 = tombstoned  (NotFound, terminated, deleted, deleting, etc.)
#   2 = unknown     (unrecognized resource type — caller should treat as alive)
# ============================================================
teardown_classify_arn() {
  local arn="$1"
  local svc type id state

  # ARN format: arn:aws:<svc>:<region>:<account>:<resource>
  # <resource> is either "<type>/<id>", "<type>:<id>", or just "<id>".
  local rest="${arn#arn:aws:}"
  svc="${rest%%:*}"; rest="${rest#*:}"   # drop svc
  rest="${rest#*:}"                       # drop region
  rest="${rest#*:}"                       # drop account

  if [[ "$rest" == */* ]]; then
    type="${rest%%/*}"
    id="${rest#*/}"
  elif [[ "$rest" == *:* ]]; then
    type="${rest%%:*}"
    id="${rest#*:}"
  else
    type=""
    id="$rest"
  fi

  case "${svc}:${type}" in
    ec2:instance)
      state="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" \
                 --query 'Reservations[0].Instances[0].State.Name' \
                 --output text 2>/dev/null || true)"
      case "$state" in
        ""|None|terminated|shutting-down) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    ec2:volume)
      state="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$id" \
                 --query 'Volumes[0].State' --output text 2>/dev/null || true)"
      case "$state" in
        ""|None|deleted|deleting) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    ec2:network-interface)
      state="$(aws ec2 describe-network-interfaces --region "$REGION" \
                 --network-interface-ids "$id" \
                 --query 'NetworkInterfaces[0].Status' \
                 --output text 2>/dev/null || true)"
      case "$state" in
        ""|None) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    ec2:natgateway)
      state="$(aws ec2 describe-nat-gateways --region "$REGION" \
                 --nat-gateway-ids "$id" \
                 --query 'NatGateways[0].State' \
                 --output text 2>/dev/null || true)"
      case "$state" in
        ""|None|deleted|deleting|failed) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    ec2:vpc)
      state="$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$id" \
                 --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    ec2:subnet)
      state="$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$id" \
                 --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    ec2:security-group)
      state="$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$id" \
                 --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    ec2:internet-gateway)
      state="$(aws ec2 describe-internet-gateways --region "$REGION" \
                 --internet-gateway-ids "$id" \
                 --query 'InternetGateways[0].InternetGatewayId' \
                 --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    ec2:route-table)
      state="$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$id" \
                 --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    ec2:elastic-ip)
      state="$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$id" \
                 --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)"
      [[ "$state" == "$id" ]] && return 0 || return 1
      ;;
    *)
      return 2
      ;;
  esac
}

# ============================================================
# Step 10: Final tag-based verification sweep
# ============================================================
step_10_tag_sweep() {
  log_step "10 — Final verification: tag sweep"

  log_info "Scanning for any remaining resources tagged '${TAG_KEY}=${TAG_VALUE}'..."

  local remaining
  remaining="$(aws resourcegroupstaggingapi get-resources \
    --region "$REGION" \
    --tag-filters "Key=${TAG_KEY},Values=${TAG_VALUE}" \
    --query "ResourceTagMappingList[*].ResourceARN" \
    --output json 2>/dev/null || echo "[]")"

  local count
  count="$(echo "$remaining" | jq 'length' 2>/dev/null || echo "0")"

  if [ "$count" = "0" ] || [ -z "$count" ]; then
    log_success "Tag sweep: 0 resources tagged '${TAG_KEY}=${TAG_VALUE}' remain."
    return 0
  fi

  log_info "Tag sweep returned ${count} ARN(s). Cross-checking each against real state..."

  local alive=()
  local tombstoned=()
  local unknown=()
  local arn rc

  # Use process substitution (not a pipe) so array writes happen in this
  # shell — a piped `while` runs in a subshell and silently drops them.
  while IFS= read -r arn; do
    [ -z "$arn" ] && continue
    set +e
    teardown_classify_arn "$arn"
    rc=$?
    set -e
    case $rc in
      0) alive+=("$arn") ;;
      1) tombstoned+=("$arn") ;;
      *) unknown+=("$arn") ;;
    esac
  done < <(echo "$remaining" | jq -r '.[]')

  if [ ${#tombstoned[@]} -gt 0 ]; then
    log_info "Ignoring ${#tombstoned[@]} stale tag-sweep entr$( [ ${#tombstoned[@]} -eq 1 ] && echo "y" || echo "ies") (already deleted; AWS retains tombstones for ~1h):"
    for arn in "${tombstoned[@]}"; do
      log_info "    - ${arn}"
    done
  fi

  if [ ${#unknown[@]} -gt 0 ]; then
    log_warn "Tag sweep found ${#unknown[@]} resource(s) of unrecognized type. Treating as alive:"
    for arn in "${unknown[@]}"; do
      log_warn "    - ${arn}"
      alive+=("$arn")
    done
  fi

  if [ ${#alive[@]} -eq 0 ]; then
    log_success "Tag sweep: 0 live resources remain (all ${count} entries were stale tombstones)."
    return 0
  fi

  log_warn "Tag sweep found ${#alive[@]} LIVE resource(s) still tagged '${TAG_KEY}=${TAG_VALUE}'. Manual cleanup needed:"
  echo ""
  for arn in "${alive[@]}"; do
    echo "  ${arn}"
    mark_failed "Remaining resource: ${arn}"
  done
  echo ""
  echo "For each ARN above, determine the resource type and delete via AWS Console or CLI."
  return 1
}

# ============================================================
# Summary
# ============================================================
print_summary() {
  local has_failures=${1:-false}

  echo ""
  if ! $has_failures; then
    echo -e "${GREEN}${BOLD}=================================================${RESET}"
    echo -e "${GREEN}${BOLD}  AWS Teardown Complete${RESET}"
    echo -e "${GREEN}${BOLD}=================================================${RESET}"
    echo -e "  Deleted:"
    for item in "${DELETED_ITEMS[@]:-}"; do
      [ -z "$item" ] && continue
      echo -e "    ${GREEN}✓${RESET} ${item}"
    done
    echo ""
    echo -e "  Tag sweep: ${GREEN}0 resources${RESET} tagged '${TAG_KEY}=${TAG_VALUE}' remain."
    echo -e "  ${GREEN}Your AWS bill is clear.${RESET}"
    echo -e "${GREEN}${BOLD}=================================================${RESET}"
  else
    echo -e "${YELLOW}${BOLD}=================================================${RESET}"
    echo -e "${YELLOW}${BOLD}  AWS Teardown INCOMPLETE — manual action needed${RESET}"
    echo -e "${YELLOW}${BOLD}=================================================${RESET}"
    if [ ${#DELETED_ITEMS[@]} -gt 0 ]; then
      echo -e "  Deleted:"
      for item in "${DELETED_ITEMS[@]:-}"; do
        [ -z "$item" ] && continue
        echo -e "    ${GREEN}✓${RESET} ${item}"
      done
      echo ""
    fi
    echo -e "  ${RED}Could not delete:${RESET}"
    for item in "${FAILED_ITEMS[@]:-}"; do
      [ -z "$item" ] && continue
      echo -e "    ${RED}✗${RESET} ${item}"
    done
    echo ""
    echo "  Review the errors above and delete remaining resources manually."
    echo "  Re-run './scripts/teardown-aws.sh' after resolving issues."
    echo -e "${YELLOW}${BOLD}=================================================${RESET}"
  fi
  echo ""
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  check_env_file

  echo ""
  echo -e "${BOLD}OpenTelemetry Demo — AWS Teardown${RESET}"
  echo -e "Cluster: ${CYAN}${CLUSTER_NAME}${RESET}  |  Region: ${CYAN}${REGION:-<resolving>}${RESET}"
  echo ""

  step_1_validate
  step_2_uninstall_demo
  step_3_wait_nlb
  step_4_delete_pvcs
  step_5_uninstall_lb_controller
  step_6_delete_namespace
  step_7_delete_iam_serviceaccount
  step_8_delete_cluster
  step_9_delete_log_groups
  step_9b_delete_iam_policy

  local sweep_failed=false
  step_10_tag_sweep || sweep_failed=true

  local has_failures=false
  if [ ${#FAILED_ITEMS[@]} -gt 0 ] || $sweep_failed; then
    has_failures=true
  fi

  print_summary $has_failures

  if $has_failures; then
    exit 1
  fi
}

main "$@"
