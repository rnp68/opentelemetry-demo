<!-- markdownlint-disable MD013 -->

# AWS EKS Deployment Guide

Deploy the complete OpenTelemetry Demo on Amazon Web Services with a single command. The deployment
script provisions an EKS cluster, installs all Kubernetes prerequisites, and deploys the full
observability stack via the official OpenTelemetry Helm chart — with zero manual steps once your
AWS credentials are configured.

> **Cost estimate:** ~$390/month (On-Demand) or ~$130/month (Spot instances).
> **Always run the teardown when you're done** — see [Removing All AWS Resources](#removing-all-aws-resources).

---

## Table of Contents

- [Overview](#overview)
- [AWS Architecture](#aws-architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Walkthrough](#deployment-walkthrough)
- [Configuration Options](#configuration-options)
- [Configuration](#configuration)
- [Cost Reference](#cost-reference)
- [Accessing the Demo](#accessing-the-demo)
- [Idempotency — Running the Script Multiple Times](#idempotency--running-the-script-multiple-times)
- [Removing All AWS Resources](#removing-all-aws-resources)
- [Troubleshooting](#troubleshooting)
- [IAM Permissions Reference](#iam-permissions-reference)

---

## Overview

The deployment uses:

| Component | Technology | Why |
|-----------|-----------|-----|
| Container orchestration | Amazon EKS (Kubernetes `EKS_K8S_VERSION`, default 1.33) | Matches the Kubernetes deployment of this branch |
| Cluster provisioning | `eksctl` | No Terraform state files — self-contained |
| Application deployment | Helm (`open-telemetry/opentelemetry-demo`, pinned to `OTEL_DEMO_CHART_VERSION`, default 0.37.8) | Official chart with proper lifecycle management; the pin keeps the demo version identical to the other deployment modes |
| Load balancing | AWS Network Load Balancer (NLB) | Single TCP port, cheaper than ALB |
| LB provisioning | AWS Load Balancer Controller | Manages NLB lifecycle from Kubernetes |
| Resource tracking | Tag `AWS_RESOURCE_TAG_KEY=AWS_RESOURCE_TAG_VALUE` (default `project=opentelemetry-demo`) | Used by teardown for verified cleanup |

**What gets deployed:**

- About 20 microservices (same as local Docker Compose)
- Default: full telemetry pipeline, OTel Collector → Jaeger + Prometheus + OpenSearch, with Grafana dashboards
- With `--grafana-cloud`: no local backends; the collector exports to Grafana Cloud (fewer pods, cheaper)
- Feature flag service (flagd)
- Load generator (Locust)
- Public URL via internet-facing Network Load Balancer

---

## AWS Architecture

```text
                           Internet
                               │
                    ┌──────────▼──────────┐
                    │  Network Load       │
                    │  Balancer (NLB)     │
                    │  :8080 (TCP)        │
                    └──────────┬──────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                  AWS VPC                     │
        │     ┌─────────────────────────────────┐     │
        │     │        EKS Cluster              │     │
        │     │   Namespace: otel-demo          │     │
        │     │                                 │     │
        │     │  ┌────────────────────────────┐ │     │
        │     │  │   Worker Node Group        │ │     │
        │     │  │   2x t3.xlarge (default)   │ │     │
        │     │  │   ┌──────────┬──────────┐  │ │     │
        │     │  │   │  Node 1  │  Node 2  │  │ │     │
        │     │  │   │          │          │  │ │     │
        │     │  │   │ frontend │ checkout │  │ │     │
        │     │  │   │ otel-    │ jaeger   │  │ │     │
        │     │  │   │ grafana  │ prometheus│  │ │     │
        │     │  │   │ opensrch │ kafka    │  │ │     │
        │     │  │   │  (+ 14 more pods)   │  │ │     │
        │     │  │   └──────────┴──────────┘  │ │     │
        │     │  └────────────────────────────┘ │     │
        │     │                                 │     │
        │     │  kube-system:                   │     │
        │     │  ┌──────────────────────────┐   │     │
        │     │  │ AWS Load Balancer Ctrl   │   │     │
        │     │  │ metrics-server           │   │     │
        │     │  └──────────────────────────┘   │     │
        │     └─────────────────────────────────┘     │
        │                                             │
        │  ┌────────────────┐  ┌───────────────────┐  │
        │  │  Public Subnet │  │  Private Subnets  │  │
        │  │  NAT Gateway   │  │  (worker nodes)   │  │
        │  └────────────────┘  └───────────────────┘  │
        └─────────────────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │    AWS Services     │
                    │  CloudWatch Logs    │
                    │  IAM (OIDC/IRSA)   │
                    │  CloudFormation     │
                    └─────────────────────┘
```

---

## Prerequisites

The deployment script automatically checks and installs missing tools. Here is what it needs:

| Tool | Minimum Version | Auto-Install | Manual Install |
|------|----------------|:------------:|----------------|
| `aws` CLI | v2.x | Mac (brew) / Linux (apt/yum/dnf) | [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| `eksctl` | 0.170+ | Mac (brew tap weaveworks) / Linux (GitHub releases) | [eksctl.io](https://eksctl.io/installation/) |
| `kubectl` | 1.28+ | Mac (brew) / Linux (apt) | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.14+ | Mac (brew) / Linux (snap) | [helm.sh](https://helm.sh/docs/intro/install/) |
| `jq` | 1.6+ | Mac (brew) / Linux (apt) | [jqlang.github.io](https://jqlang.github.io/jq/download/) |
| **AWS credentials** | — | **Cannot auto-install** | See [Credentials Setup](#phase-2--aws-credentials-validation) |

> **Note:** The script detects your OS and uses the appropriate package manager. On macOS it uses
> Homebrew; on Linux it tries `apt-get`, `yum`, or `dnf` in that order. If no package manager is found,
> it prints the manual install URL and exits with code 1.

---

## Quick Start

```bash
# 1. Clone the repository (if not already done)
git clone https://github.com/rnp68/opentelemetry-demo.git
cd opentelemetry-demo
git checkout workshop

# 2. Deploy to AWS (one command). The first run creates .env.local from
#    .env.example; see "Configuration" below for the values it reads.
./scripts/deploy-aws.sh

#    Grafana Cloud instead of local Jaeger/Prometheus/Grafana (set the three
#    GRAFANA_* values in .env.local first, see docs/deployment-guide.md section 4):
./scripts/deploy-aws.sh --grafana-cloud
```

The script will:

1. Check and install any missing prerequisites
2. Validate your AWS credentials
3. Show a cost estimate and ask for confirmation
4. Provision the EKS cluster (~15 minutes)
5. Install Kubernetes prerequisites
6. Deploy the full demo via Helm (~5 minutes)
7. Print the public URL

**To use Spot instances (~60% cheaper):**

```bash
./scripts/deploy-aws.sh --spot
```

**Teardown when done:**

```bash
./scripts/teardown-aws.sh
# or: make teardown-aws
```

---

## Deployment Walkthrough

The script executes six phases in sequence. Each phase is idempotent — if it has already completed
successfully, the script skips it and moves on.

### Phase 1 — Tool Prerequisite Check

The script checks each required tool in order. For each tool:

1. Checks if the binary exists in `PATH`
2. If found, verifies the version meets the minimum requirement
3. If missing or outdated, attempts auto-install using the detected package manager
4. Re-verifies after install
5. If install fails, prints the manual install URL and exits

**Example output (all tools present):**

```text
==> Phase 1: Checking prerequisites
[OK]    aws CLI 2.15.30
[OK]    eksctl 0.175.0
[OK]    kubectl v1.29.2
[OK]    helm v3.14.0
[OK]    jq 1.7.1
[OK]    All prerequisites satisfied.
```

**Example output (eksctl missing — auto-install):**

```text
[WARN]  eksctl not found. Attempting install...
==> brew tap weaveworks/tap && brew install weaveworks/tap/eksctl
...
[OK]    eksctl 0.175.0
```

### Phase 2 — AWS Credentials Validation

The script runs `aws sts get-caller-identity` to verify your credentials are valid. This is the only
prerequisite that **cannot be auto-fixed** — it requires your AWS access keys or SSO session.

**If credentials are valid:**

```text
==> Phase 2: Validating AWS credentials and region
[INFO]  AWS region: us-east-1
[OK]    Authenticated as: arn:aws:iam::123456789:user/your-name (account: 123456789)

COST ESTIMATE
  EKS cluster 'otel-demo' in us-east-1: ~$390/month
  Components: EKS control plane + 2x t3.xlarge nodes + NLB + NAT Gateway
  Run './scripts/teardown-aws.sh' when done to avoid ongoing charges.

Proceed with deployment? [y/N]
```

**If credentials are missing or invalid:**

```text
[ERROR] AWS credentials are not configured or are invalid.

AWS CLI error:
Unable to locate credentials. You can configure credentials by running "aws configure".

How to configure AWS credentials:

  Option 1 — Interactive setup:
    aws configure
    (Enter your Access Key ID, Secret Access Key, region, and output format)

  Option 2 — Environment variables:
    export AWS_ACCESS_KEY_ID=<your-key>
    export AWS_SECRET_ACCESS_KEY=<your-secret>
    export AWS_SESSION_TOKEN=<token>   # if using temporary credentials
    export AWS_DEFAULT_REGION=us-east-1

  Option 3 — AWS SSO:
    aws sso login

Required IAM permissions:
  Your IAM user/role needs the following permissions:
  - AmazonEKSClusterPolicy
  - AmazonEKSWorkerNodePolicy
  ...
```

See [IAM Permissions Reference](#iam-permissions-reference) for the complete list.

### Phase 3 — EKS Cluster Provisioning

The script checks whether the cluster already exists. If it does, this phase is skipped (idempotent).
If not, it generates a temporary `eksctl` cluster config and creates the cluster.

**Cluster configuration:**

| Setting | Value |
|---------|-------|
| Kubernetes version | `EKS_K8S_VERSION` (default 1.33) |
| Node type | `t3.xlarge` (4 vCPU, 16 GiB) |
| Default node count | 2 |
| Auto-scaling | Min 1, Max 4 |
| Capacity type | On-Demand (or Spot with `--spot`) |
| VPC | Dedicated (created by eksctl) |
| IAM OIDC | Enabled (required for AWS LB Controller) |
| Resource tags | `project=opentelemetry-demo` |

**Why t3.xlarge?** The full demo with OpenSearch (1 GiB memory limit) and 22 microservices requires
approximately 5.5 GiB of schedulable memory. Two `t3.xlarge` nodes (30 GiB total system minus OS
overhead ≈ 26 GiB schedulable) provide comfortable headroom for the workloads.

**Expected duration:** 12–18 minutes (EKS control plane provisioning + managed node group creation).

```text
==> Phase 3: EKS cluster provisioning
[INFO]  Creating EKS cluster 'otel-demo' in us-east-1 (this takes ~15 minutes)...
2024-01-15 10:23:01 [ℹ]  eksctl version 0.175.0
2024-01-15 10:23:01 [ℹ]  creating EKS cluster "otel-demo" in "us-east-1" region with managed nodes
...
2024-01-15 10:38:47 [✔]  EKS cluster "otel-demo" in "us-east-1" region is ready
[OK]    Cluster 'otel-demo' created.
```

### Phase 4 — Kubernetes Prerequisites

Two components are installed before the demo chart:

**AWS Load Balancer Controller** — provisions and manages the AWS NLB that exposes the frontend. It
uses an IAM service account (IRSA) with a specific IAM policy allowing it to call `elasticloadbalancing:*`
and `ec2:*` APIs.

**metrics-server** — enables `kubectl top` and Horizontal Pod Autoscaler support.

Both are checked for existence before installing (idempotent).

### Phase 5 — Helm Chart Deployment

```bash
helm upgrade --install opentelemetry-demo open-telemetry/opentelemetry-demo \
  --version 0.37.8 \
  --namespace otel-demo \
  --create-namespace \
  --wait \
  --timeout 15m \
  --values /tmp/otel-demo-values.XXXXXX.yaml \
  [--values kubernetes/values-grafana-cloud.yaml]     # only with --grafana-cloud
```

(Version, namespace and release name come from `OTEL_DEMO_CHART_VERSION`,
`OTEL_DEMO_NAMESPACE` and `OTEL_DEMO_RELEASE`.) With `--grafana-cloud` the script
first creates the Kubernetes secret `grafana-cloud-otlp` from `.env.local`, so no
credential is ever written to a values file.

The values file overrides the frontend proxy service to use an internet-facing NLB:

```yaml
components:
  frontend-proxy:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
        tags: "<AWS_RESOURCE_TAG_KEY>=<AWS_RESOURCE_TAG_VALUE>"
```

The `--wait --timeout 15m` flags block until all Kubernetes Deployments are `Available`. If any pod
fails to start within 15 minutes, the script exits with the failing pod's logs.

### Phase 6 — URL Retrieval

After Helm completes, the script polls the `frontend-proxy` Service every 10 seconds (up to 3 minutes)
for the NLB hostname. AWS typically provisions the NLB in 60–90 seconds.

```text
=================================================
  OpenTelemetry Demo is LIVE on AWS!
=================================================
  Frontend:    http://a1b2c3d4e5f6.elb.us-east-1.amazonaws.com:8080
  Grafana:     http://a1b2c3d4e5f6.elb.us-east-1.amazonaws.com:8080/grafana/       (not shown with --grafana-cloud)
  Jaeger:      http://a1b2c3d4e5f6.elb.us-east-1.amazonaws.com:8080/jaeger/ui       (not shown with --grafana-cloud)
  Load Gen:    http://a1b2c3d4e5f6.elb.us-east-1.amazonaws.com:8080/loadgen/
=================================================
  Teardown:    ./scripts/teardown-aws.sh
  Cost est:    ~$390/month
=================================================
```

---

## Configuration Options

| Flag | Description | Default |
|------|-------------|---------|
| `--cluster-name NAME` | Name for the EKS cluster | `EKS_CLUSTER_NAME`, then `otel-demo` |
| `--region REGION` | AWS region to deploy into | `AWS_REGION`, then `$AWS_DEFAULT_REGION`, then `aws configure get region`, then `us-east-1` |
| `--spot` | Use Spot instances instead of On-Demand (~60% cheaper) | Off (On-Demand) |
| `--grafana-cloud` | Send telemetry to Grafana Cloud; skip Jaeger, Prometheus, Grafana, OpenSearch | Off |
| `--yes` or `-y` | Skip all confirmation prompts (for CI/CD) | Off (interactive) |
| `--dry-run` | Print what would be done without making changes | Off |
| `--destroy` | Tear down all resources (delegates to `teardown-aws.sh`) | — |

**Examples:**

```bash
# Deploy to eu-west-1 with Spot instances, no confirmation
./scripts/deploy-aws.sh --region eu-west-1 --spot --yes

# See what would be deployed without touching anything
./scripts/deploy-aws.sh --dry-run

# Deploy with a custom cluster name
./scripts/deploy-aws.sh --cluster-name my-otel-demo --region us-west-2

# Lean deployment to Grafana Cloud
./scripts/deploy-aws.sh --grafana-cloud --spot

# Tear down (same as running teardown-aws.sh directly)
./scripts/deploy-aws.sh --destroy
```

---

## Configuration

Sizing, tags and versions are not flags; they come from `.env.local` (template
`.env.example`, full reference in [configuration.md](configuration.md)). Both scripts
create `.env.local` when it is missing and use the defaults below for anything left as
`unknown`.

| Variable | Default | Effect |
|---|---|---|
| `AWS_REGION` | `AWS_DEFAULT_REGION`, then `aws configure`, then `us-east-1` | region |
| `EKS_CLUSTER_NAME` | `otel-demo` | cluster name |
| `EKS_K8S_VERSION` | `1.33` | Kubernetes version |
| `EKS_NODE_TYPE` / `EKS_NODE_COUNT` / `EKS_NODE_MIN` / `EKS_NODE_MAX` | `t3.xlarge` / `2` / `1` / `4` | node group |
| `AWS_RESOURCE_TAG_KEY` / `AWS_RESOURCE_TAG_VALUE` | `project` / `opentelemetry-demo` | tag on every resource; **keep identical for deploy and teardown** |
| `OTEL_DEMO_CHART_VERSION` | `0.37.8` | Helm chart (demo 2.0.2) |
| `OTEL_DEMO_NAMESPACE` / `OTEL_DEMO_RELEASE` | `otel-demo` / `opentelemetry-demo` | where and under which name |
| `GRAFANA_OTLP_ENDPOINT`, `GRAFANA_INSTANCE_ID`, `GRAFANA_CLOUD_APIKEY` | none (required by `--grafana-cloud`) | Grafana Cloud export |

**Faro and Pyroscope are not available on AWS** through this script: they need the
`frontend` and `checkout` images built from this repository, and EKS cannot see local
images. See [faro-and-pyroscope.md](faro-and-pyroscope.md#why-the-images-must-be-built-locally).

---

## Cost Reference

Costs are estimates based on AWS us-east-1 pricing. Actual costs vary by region and usage.

| Resource | Type | On-Demand/month | Spot/month |
|----------|------|:-----------------:|:----------:|
| EKS Control Plane | Managed | ~$73 | ~$73 (fixed) |
| 2× `t3.xlarge` EC2 nodes | Compute | ~$240 | ~$72–96 |
| Network Load Balancer | NLB | ~$18 | ~$18 (fixed) |
| NAT Gateway | Network | ~$45 | ~$45 (fixed) |
| EBS volumes (gp3, ~50 GiB) | Storage | ~$8 | ~$8 (fixed) |
| CloudWatch Logs | Monitoring | ~$5 | ~$5 (fixed) |
| **Total estimate** | | **~$389/month** | **~$219–243/month** |

> **Warning:** EKS costs accrue 24/7, including when no one is using the demo. A cluster left running
> for a full month costs ~$390. Always run `./scripts/teardown-aws.sh` when the demo is complete.

**Spot instance trade-off:** Spot instances can be interrupted by AWS with a 2-minute warning when
capacity is reclaimed. For demo purposes this is usually acceptable. The node group is configured with
auto-scaling (min 1, max 4) so Kubernetes will reschedule pods to new Spot nodes if an interruption
occurs.

---

## Accessing the Demo

Once deployed, all entry points are routed through Envoy (`frontend-proxy`), which proxies to internal
services. Replace `<NLB_HOSTNAME>` with the hostname printed at the end of deployment.

| Interface | URL | Description |
|-----------|-----|-------------|
| Astronomy Shop | `http://<NLB_HOSTNAME>:8080` | Main demo application — browse, add to cart, checkout |
| Grafana | `http://<NLB_HOSTNAME>:8080/grafana/` | Pre-configured dashboards with traces, metrics, logs |
| Jaeger | `http://<NLB_HOSTNAME>:8080/jaeger/ui` | Distributed trace explorer |
| Load Generator | `http://<NLB_HOSTNAME>:8080/loadgen/` | Locust UI — adjust traffic volume, view request stats |
| Feature Flags | `http://<NLB_HOSTNAME>:8080/feature/` | Toggle failure scenarios (payment failure, high CPU, etc.) |
| OTel Collector metrics | `http://<NLB_HOSTNAME>:8080/otlp-http/` | Raw OTLP HTTP endpoint (for custom exporters) |

---

## Idempotency — Running the Script Multiple Times

The script is designed to be safely run multiple times. Each phase checks the current state before
acting:

| Phase | Already done? | Behavior |
|-------|:-------------:|---------|
| Tool install | Tool present | Skip — report current version |
| AWS validation | Credentials valid | Continue — re-confirm region |
| EKS cluster | Cluster exists | Skip creation — update kubeconfig |
| IAM service account | Account exists | Skip (`--override-existing-serviceaccounts` handles updates) |
| LB Controller | Helm release present | Skip install |
| metrics-server | Deployment exists | Skip apply |
| Helm deploy | Release exists | `helm upgrade` — no-op if chart unchanged, upgrade if updated |

Running the script again after a failed deployment resumes from where it left off.

---

## Removing All AWS Resources

> **This is the most important section.** AWS resources cost money until they are deleted.
> Never just delete the cluster without following the procedure below — you risk orphaned resources
> that continue accruing charges.

### Why Deletion Order Matters

The AWS Load Balancer Controller creates a Network Load Balancer as a cloud resource, **not** a
Kubernetes resource. This means:

- `eksctl delete cluster` does **not** delete the NLB
- The NLB keeps Elastic Network Interfaces (ENIs) attached to the VPC
- With ENIs present, `eksctl` cannot delete the VPC → the cluster deletion fails
- The NLB continues billing even after the cluster is gone

The teardown script enforces the correct 10-step deletion sequence to prevent this.

### Deletion Sequence Diagram

```text
Step 2: Helm uninstall opentelemetry-demo
         └── triggers: LB Controller finalizer deletes NLB
Step 3: Wait for NLB to fully decommission
         └── polls aws elbv2 until VPC has zero load balancers
Step 4: Delete PVCs (triggers EBS volume deletion)
Step 5: Helm uninstall aws-load-balancer-controller
Step 6: Delete namespace otel-demo
Step 7: eksctl delete iamserviceaccount (removes IRSA role)
Step 8: eksctl delete cluster
         └── deletes: node groups, VPC, subnets, security groups,
             NAT gateway, internet gateway, route tables,
             IAM node roles, CloudFormation stacks
Step 9: Delete CloudWatch log groups /aws/eks/otel-demo/*
Step 9b: Delete IAM policy AWSLoadBalancerControllerIAMPolicy
Step 10: Tag sweep — verify zero resources remain
```

### Running the Teardown

```bash
./scripts/teardown-aws.sh
```

Or via Make:

```bash
make teardown-aws
```

The script will show what it's about to delete and require you to type the cluster name to confirm:

```text
WARNING: DESTRUCTIVE OPERATION

This will PERMANENTLY DELETE:
  - EKS cluster 'otel-demo' in us-east-1
  - All worker nodes (EC2 instances)
  - All Kubernetes workloads and data
  - Network Load Balancer
  - VPC, subnets, security groups, NAT gateway, internet gateway
  - IAM roles and policies for this cluster
  - CloudWatch log groups: /aws/eks/otel-demo/*

To confirm, type the cluster name: otel-demo
_
```

**To skip confirmation (CI/CD pipelines):**

```bash
./scripts/teardown-aws.sh --yes
```

### Teardown Progress Output

Each of the 10 steps reports its status. A successful teardown looks like:

```text
Step 2 — Uninstalling Helm release: opentelemetry-demo
[INFO]  Uninstalling 'opentelemetry-demo' (this triggers NLB deletion via LB Controller)...
[✓]     Helm release 'opentelemetry-demo' uninstalled.

Step 3 — Waiting for Network Load Balancer decommission
[INFO]  Checking for NLBs in VPC vpc-0abc123...
[INFO]  Waiting for 1 load balancer(s) to decommission... (1/30)
[INFO]  Waiting for 1 load balancer(s) to decommission... (2/30)
[✓]     No load balancers remaining in VPC vpc-0abc123.

Step 4 — Deleting Persistent Volume Claims
[INFO]  Deleting 3 PVC(s) in namespace 'otel-demo'...
[✓]     EBS volumes deleted.

...

Step 10 — Final verification: tag sweep
[INFO]  Scanning for any remaining resources tagged 'project=opentelemetry-demo'...
[✓]     Tag sweep: 0 resources tagged 'project=opentelemetry-demo' remain.

=================================================
  AWS Teardown Complete
=================================================
  Deleted:
    ✓ Helm release: opentelemetry-demo
    ✓ Network Load Balancer
    ✓ EBS Persistent Volumes (3 PVCs)
    ✓ Helm release: aws-load-balancer-controller
    ✓ Kubernetes namespace: otel-demo
    ✓ IAM service account: aws-load-balancer-controller
    ✓ EKS cluster: otel-demo (+ VPC, subnets, SGs, NAT GW, IAM roles)
    ✓ CloudWatch log groups: /aws/eks/otel-demo/*
    ✓ IAM policy: AWSLoadBalancerControllerIAMPolicy

  Tag sweep: 0 resources tagged 'project=opentelemetry-demo' remain.
  Your AWS bill is clear.
=================================================
```

### If Teardown Is Incomplete

If a step fails (e.g., an NLB that didn't fully decommission), the script reports the ARNs of
remaining resources and exits with code 1:

```text
=================================================
  AWS Teardown INCOMPLETE — manual action needed
=================================================
  Could not delete:
    ✗ Network Load Balancer (may still exist)
    ✗ Remaining resource: arn:aws:elasticloadbalancing:us-east-1:...

  Review the errors above and delete remaining resources manually.
  Re-run './scripts/teardown-aws.sh' after resolving issues.
=================================================
```

The teardown script is **idempotent** — safely re-run it after resolving any manual cleanup. Each
step checks for existence before attempting deletion.

**Manual verification after any teardown:**

```bash
# Check for any remaining tagged resources in your region
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=opentelemetry-demo \
  --region us-east-1 \
  --output table
```

If this command returns an empty `ResourceTagMappingList`, your AWS account has no remaining resources
from this deployment.

### Teardown Script Options

| Flag | Description | Default |
|------|-------------|---------|
| `--cluster-name NAME` | Name of the cluster to tear down | `otel-demo` |
| `--region REGION` | AWS region | Same resolution as deploy script |
| `--yes` or `-y` | Skip the cluster-name confirmation prompt | Off (interactive) |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Phase 1: `brew: command not found` on macOS | Homebrew not installed | Install from <https://brew.sh>, then re-run |
| Phase 2: `Unable to locate credentials` | No AWS credentials configured | Run `aws configure` or set `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` |
| Phase 2: `ExpiredToken` | Temporary credentials expired | Refresh credentials (`aws sso login` or get new temporary keys) |
| Phase 3: `AccessDeniedException` during cluster create | IAM user lacks required permissions | See [IAM Permissions Reference](#iam-permissions-reference) |
| Phase 3: Cluster creation stuck >25 min | CloudFormation stack in `ROLLBACK` state | Check AWS CloudFormation console; delete stuck stacks manually |
| Phase 4: LB Controller pod in `CrashLoopBackOff` | IAM OIDC provider not properly created | `eksctl utils associate-iam-oidc-provider --cluster otel-demo --approve` |
| Phase 5: Helm timeout after 15 min | OpenSearch pod out of memory or unschedulable | Check with `kubectl describe pod -n otel-demo -l app=opensearch`; try larger nodes |
| Phase 5: `Error: INSTALLATION FAILED` | Namespace already has a partial release | `helm uninstall opentelemetry-demo -n otel-demo`, then re-run deploy |
| Phase 6: NLB hostname never appears | NLB provisioning failed | Check `kubectl describe service frontend-proxy -n otel-demo` for events |
| App loads but shows no data | OTel Collector not forwarding to backends | Check `kubectl logs -n otel-demo deploy/otel-collector` |
| Teardown: VPC deletion fails | NLB ENIs still attached | Wait 5 min for NLB decommission, then re-run `teardown-aws.sh` |
| Teardown: `eksctl delete cluster` hangs | Orphaned CloudFormation resources | Check CloudFormation console in AWS; manually delete stuck stacks |
| Unexpected bill after teardown | Resources not tagged `project=opentelemetry-demo` | Run the tag sweep command above; check for orphaned CloudFormation stacks |

---

## IAM Permissions Reference

Your AWS IAM user or role needs the following permissions. The minimal policy set is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSManagement",
      "Effect": "Allow",
      "Action": [
        "eks:CreateCluster",
        "eks:DeleteCluster",
        "eks:DescribeCluster",
        "eks:UpdateClusterConfig",
        "eks:CreateNodegroup",
        "eks:DeleteNodegroup",
        "eks:DescribeNodegroup",
        "eks:CreateFargateProfile",
        "eks:TagResource",
        "eks:UntagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ForEKS",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:CreateNatGateway",
        "ec2:DeleteNatGateway",
        "ec2:DescribeNatGateways",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:CreateRoute",
        "ec2:AssociateRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeKeyPairs",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeVolumes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForEKS",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:PassRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:ListEntitiesForPolicy",
        "iam:TagRole",
        "iam:TagPolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFormationForEksctl",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:UpdateStack",
        "cloudformation:ValidateTemplate",
        "cloudformation:ListStacks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ELBForLBController",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ResourceTaggingAPI",
      "Effect": "Allow",
      "Action": [
        "tag:GetResources",
        "tag:GetTagKeys",
        "tag:GetTagValues"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STSForCredentialValidation",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity",
        "sts:AssumeRole"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Tip:** For a quick start with an IAM admin user, the managed policies `AdministratorAccess` or
> a combination of `AmazonEKSClusterPolicy` + `AmazonEC2FullAccess` + `IAMFullAccess` +
> `AWSCloudFormationFullAccess` will work. The fine-grained policy above is for production-grade
> least-privilege access.
