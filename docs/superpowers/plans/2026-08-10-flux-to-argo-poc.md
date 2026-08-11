# Zero-Downtime Flux → ArgoCD Migration PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a scripted, reproducible PoC that migrates a classic 3-tier guestbook app from a Flux `HelmRelease` (in a local k3d cluster) to an Akuity-hosted ArgoCD `Application`, with zero downtime proven by a continuous verification probe.

**Architecture:** One k3d cluster runs Flux and the guestbook workload; a dedicated Akuity Platform (AKP) instance, provisioned via Terraform, hosts the ArgoCD control plane and registers the k3d cluster as a workload cluster. Both controllers pull the same Helm chart from `adamancini/flux-to-argo` on GitHub. A `Taskfile.yml` drives every step; numbered scripts under `scripts/` do the work; `README.md` narrates each step for a human running it live.

**Tech Stack:** k3d, Flux (`flux` CLI, `source-controller`/`helm-controller`), Helm 3, Terraform (`akuity/akp` provider), `argocd` CLI, `akuity` platform (Akuity-hosted ArgoCD), `gh` CLI, go-task (`Taskfile.yml`), bash, `jq`, `curl`.

## Global Constraints

- Spec of record: `docs/superpowers/specs/2026-08-10-flux-to-argo-poc-design.md` — every task below implements one part of it; consult it for the "why" behind any step.
- Required local tools, assumed already installed and authenticated: `k3d`, `kubectl`, `helm` (v3), `flux` CLI, `terraform` (>= 1.5), `argocd` CLI, `gh` CLI (authenticated), `jq`, `curl`, `task` (go-task). Installing these is out of scope.
- `AKUITY_API_KEY_ID` / `AKUITY_API_KEY_SECRET` env vars are assumed already set before any `terraform apply` in this plan runs, per `akp-infra`'s convention. Setting up that auth is out of scope.
- The guestbook images are assumed publicly pullable; no private registry auth is set up.
- **Real-world actions requiring explicit confirmation at execution time** (not to be run unattended by an agent without checking with the user first): `terraform apply`/`destroy` against the live Akuity org (Task 4, Task 9 — creates/destroys a real billable AKP instance), and `gh repo create` (Task 5 — creates a real public GitHub repo; already approved by the user as `adamancini/flux-to-argo`, public, during design, but only run it once). `terraform validate`/`plan` are safe to run freely.
- Namespaces: Flux objects (`GitRepository`, `HelmRelease`) live in `flux-system`; the guestbook workload lives in `guestbook-demo`; the k3d cluster is named `flux-to-argo`; the AKP-registered cluster name is also `flux-to-argo`.
- k3d (not kind) is used for the local cluster: kind cannot start a control-plane pod on this development machine's Docker Desktop install (nested containerd/runc `seccomp is not supported`, reproduced across Kubernetes versions) — see the spec's Architecture section.

---

### Task 1: Repo scaffolding — Taskfile, gitignore, README skeleton

**Files:**
- Create: `Taskfile.yml`
- Create: `.gitignore`
- Create: `README.md`

**Interfaces:**
- Produces: 8 `task` targets (`cluster:up`, `akp:up`, `deploy:flux`, `verify:start`, `verify:report`, `migrate`, `cleanup:flux`, `down`), each shelling out to a same-named script under `scripts/` that later tasks create. Running any target before its script exists is expected to fail with "no such file" until that task lands — this task only establishes the wiring.

- [ ] **Step 1: Create `Taskfile.yml`**

```yaml
version: '3'

tasks:
  cluster:up:
    desc: Create the k3d cluster and install Flux
    cmds:
      - ./scripts/cluster-up.sh

  akp:up:
    desc: Provision a dedicated Akuity Platform instance and register the k3d cluster
    cmds:
      - ./scripts/akp-up.sh

  deploy:flux:
    desc: Deploy the guestbook chart via a Flux HelmRelease
    cmds:
      - ./scripts/deploy-flux.sh

  verify:start:
    desc: Start the background availability/stability probe
    cmds:
      - ./scripts/verify-start.sh

  verify:report:
    desc: Stop the probe and print a pass/fail summary
    cmds:
      - ./scripts/verify-report.sh

  migrate:
    desc: Cut the guestbook over from Flux to the Akuity-hosted ArgoCD Application
    cmds:
      - ./scripts/migrate.sh

  cleanup:flux:
    desc: Remove the suspended Flux objects and orphaned Helm release secret
    cmds:
      - ./scripts/cleanup-flux.sh

  down:
    desc: Tear down the k3d cluster and destroy the AKP instance
    cmds:
      - ./scripts/teardown.sh
```

- [ ] **Step 2: Create `.gitignore`**

```
.task/
.verify/
*.tfstate
*.tfstate.*
.terraform/
terraform.tfvars
```

A later fix round removed `.terraform.lock.hcl` from this list: lock files are now committed for both stacks (`terraform/01-argocd/.terraform.lock.hcl`, `terraform/03-clusters/.terraform.lock.hcl`) so a fresh `terraform init` reproduces the exact same `akuity/akp` provider build every time, rather than silently resolving to whatever new 0.x version exists at init time. Only `.terraform/` (the local provider binary cache) stays ignored.

- [ ] **Step 3: Create `README.md` skeleton**

```markdown
# flux-to-argo

A small, fully-scripted proof of concept: migrate a classic 3-tier guestbook
app from a Flux `HelmRelease` to an Akuity-hosted ArgoCD `Application`,
without downtime.

See [the design spec](docs/superpowers/specs/2026-08-10-flux-to-argo-poc-design.md)
for the full rationale.

## Prerequisites

- `k3d`, `kubectl`, `helm` (v3), `flux` CLI, `terraform` (>= 1.5), `argocd`
  CLI, `gh` CLI (authenticated), `jq`, `curl`, `task` (go-task)
- `AKUITY_API_KEY_ID` / `AKUITY_API_KEY_SECRET` set in your environment

## Walkthrough

### 1. Cluster + Flux

<!-- filled in by Task 3 -->

### 2. Provision the Akuity Platform instance

<!-- filled in by Task 4 -->

### 3. Push to GitHub and deploy via Flux

<!-- filled in by Task 5 -->

### 4. Start the verification probe

<!-- filled in by Task 6 -->

### 5. Migrate to ArgoCD

<!-- filled in by Task 7 -->

### 6. Clean up Flux

<!-- filled in by Task 8 -->

### 7. Tear down

<!-- filled in by Task 9 -->
```

- [ ] **Step 4: Verify the Taskfile is valid**

Run: `task --list`
Expected: lists all 8 tasks (`cluster:up`, `akp:up`, `deploy:flux`, `verify:start`, `verify:report`, `migrate`, `cleanup:flux`, `down`) with their `desc` text, with no parse errors.

- [ ] **Step 5: Commit**

```bash
git add Taskfile.yml .gitignore README.md
git commit -m "Scaffold Taskfile, gitignore, and README skeleton"
```

---

### Task 2: Author the guestbook Helm chart

**Files:**
- Create: `chart/guestbook/Chart.yaml`
- Create: `chart/guestbook/values.yaml`
- Create: `chart/guestbook/templates/frontend-deployment.yaml`
- Create: `chart/guestbook/templates/frontend-service.yaml`
- Create: `chart/guestbook/templates/redis-leader-deployment.yaml`
- Create: `chart/guestbook/templates/redis-leader-service.yaml`
- Create: `chart/guestbook/templates/redis-follower-deployment.yaml`
- Create: `chart/guestbook/templates/redis-follower-service.yaml`

**Interfaces:**
- Produces: a Helm chart at `chart/guestbook` (name `guestbook`, version `0.1.0`) that renders 3 `Deployment`s (`frontend`, `redis-leader`, `redis-follower`) and 3 `Service`s of the same names, in the caller's target namespace (no `Namespace` resource in the chart — namespace creation is the caller's job, i.e. Flux's `install.createNamespace` or ArgoCD's `CreateNamespace=true` sync option). `frontend` Service exposes port 80 → container port 80; `redis-leader`/`redis-follower` Services expose port 6379 → container port 6379. The frontend serves guestbook HTML at `/` and a JSON get/set API at `/guestbook.php?cmd=set&key=<k>&value=<v>` and `/guestbook.php?cmd=get&key=<k>`.
- Consumes: nothing (first content task).

- [ ] **Step 1: Write the verification script for the chart (run first, expect it to fail)**

```bash
mkdir -p chart/guestbook
helm lint chart/guestbook
```

Expected: FAIL — `chart/guestbook` doesn't exist yet, so `helm lint` errors with "no such file or directory" or similar.

- [ ] **Step 2: Create `chart/guestbook/Chart.yaml`**

```yaml
apiVersion: v2
name: guestbook
description: Classic 3-tier guestbook (frontend + redis-leader + redis-follower) for the flux-to-argo migration PoC
type: application
version: 0.1.1
appVersion: "1.0"
```

- [ ] **Step 3: Create `chart/guestbook/values.yaml`**

```yaml
frontend:
  replicaCount: 1
  image:
    repository: us-docker.pkg.dev/google-samples/containers/gke/gb-frontend
    tag: v5
  service:
    port: 80

# NOTE: redisLeader and redisFollower intentionally use different images
# from different maintainers -- this is not accidental drift, do not
# "fix" them to match:
#   - redisLeader runs a plain stock Redis image; it just serves as the
#     replication master and needs no special bootstrap logic.
#   - redisFollower runs the GKE sample's purpose-built follower image,
#     which bootstraps itself as a replica against the leader on startup.
# Verified working together on a live cluster (all pods Running 1/1).
redisLeader:
  image:
    repository: docker.io/redis
    tag: 6.0.5
  service:
    port: 6379

redisFollower:
  replicaCount: 2
  image:
    repository: us-docker.pkg.dev/google-samples/containers/gke/gb-redis-follower
    tag: v2
  service:
    port: 6379
```

> Note: `redisLeader`'s replica count is hardcoded to `1` directly in `templates/redis-leader-deployment.yaml` (not templated from values, unlike the other two tiers) — see Task 2, Step 6's template and the comment added there: a Redis replication leader isn't horizontally scalable the way the follower/frontend tiers are, so there's no `redisLeader.replicaCount` value to set.

- [ ] **Step 4: Create `chart/guestbook/templates/frontend-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: guestbook
    tier: frontend
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      app: guestbook
      tier: frontend
  template:
    metadata:
      labels:
        app: guestbook
        tier: frontend
    spec:
      containers:
        - name: php-redis
          image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
          env:
            - name: GET_HOSTS_FROM
              value: "dns"
          ports:
            - containerPort: 80
```

- [ ] **Step 5: Create `chart/guestbook/templates/frontend-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  labels:
    app: guestbook
    tier: frontend
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.frontend.service.port }}
      targetPort: 80
  selector:
    app: guestbook
    tier: frontend
```

- [ ] **Step 6: Create `chart/guestbook/templates/redis-leader-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-leader
  labels:
    app: redis
    role: leader
    tier: backend
spec:
  # Hardcoded (not templated from values, unlike frontend/redisFollower):
  # a Redis replication leader isn't horizontally scalable the way the
  # follower/frontend tiers are, so there's no replicaCount to expose.
  replicas: 1
  selector:
    matchLabels:
      app: redis
      role: leader
      tier: backend
  template:
    metadata:
      labels:
        app: redis
        role: leader
        tier: backend
    spec:
      containers:
        - name: leader
          image: "{{ .Values.redisLeader.image.repository }}:{{ .Values.redisLeader.image.tag }}"
          ports:
            - containerPort: 6379
```

- [ ] **Step 7: Create `chart/guestbook/templates/redis-leader-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-leader
  labels:
    app: redis
    role: leader
    tier: backend
spec:
  ports:
    - port: {{ .Values.redisLeader.service.port }}
      targetPort: 6379
  selector:
    app: redis
    role: leader
    tier: backend
```

- [ ] **Step 8: Create `chart/guestbook/templates/redis-follower-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-follower
  labels:
    app: redis
    role: follower
    tier: backend
spec:
  replicas: {{ .Values.redisFollower.replicaCount }}
  selector:
    matchLabels:
      app: redis
      role: follower
      tier: backend
  template:
    metadata:
      labels:
        app: redis
        role: follower
        tier: backend
    spec:
      containers:
        - name: follower
          image: "{{ .Values.redisFollower.image.repository }}:{{ .Values.redisFollower.image.tag }}"
          ports:
            - containerPort: 6379
```

- [ ] **Step 9: Create `chart/guestbook/templates/redis-follower-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-follower
  labels:
    app: redis
    role: follower
    tier: backend
spec:
  ports:
    - port: {{ .Values.redisFollower.service.port }}
      targetPort: 6379
  selector:
    app: redis
    role: follower
    tier: backend
```

- [ ] **Step 10: Verify the chart lints and renders the expected resources**

Run:
```bash
helm lint chart/guestbook
helm template chart/guestbook | grep -c '^kind: Deployment'
helm template chart/guestbook | grep -c '^kind: Service'
```
Expected: `helm lint` reports `0 chart(s) failed`; both `grep -c` commands print `3`.

- [ ] **Step 11: Commit**

```bash
git add chart/guestbook
git commit -m "Add guestbook Helm chart (frontend + redis-leader + redis-follower)"
```

---

### Task 3: k3d cluster + Flux install

**Files:**
- Create: `cluster/k3d-config.yaml`
- Create: `scripts/cluster-up.sh`
- Modify: `README.md` (fill in "1. Cluster + Flux" section)

**Interfaces:**
- Consumes: nothing (chart from Task 2 isn't needed until Task 5).
- Produces: a running k3d cluster named `flux-to-argo` (kubeconfig context `k3d-flux-to-argo`), with Flux's `source-controller` and `helm-controller` `Available` in the `flux-system` namespace. Later tasks (4, 5, 7, 8, 9) assume this cluster and context exist.

- [ ] **Step 1: Create `cluster/k3d-config.yaml`**

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: flux-to-argo
servers: 1
agents: 0
```

- [ ] **Step 2: Create `scripts/cluster-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="flux-to-argo"

if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "k3d cluster '${CLUSTER_NAME}' already exists, skipping create"
else
  k3d cluster create --config cluster/k3d-config.yaml
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"

flux install

kubectl wait --for=condition=available --timeout=120s \
  -n flux-system deployment/source-controller deployment/helm-controller
```

- [ ] **Step 3: Make the script executable**

```bash
chmod +x scripts/cluster-up.sh
```

- [ ] **Step 4: Run it and verify the cluster and Flux come up**

Run:
```bash
./scripts/cluster-up.sh
kubectl get nodes
kubectl get deployment -n flux-system source-controller helm-controller
```
Expected: one node in `Ready` status; both deployments show `1/1` under `AVAILABLE`.

- [ ] **Step 5: Fill in the README's "1. Cluster + Flux" section**

Replace `<!-- filled in by Task 3 -->` under `### 1. Cluster + Flux` with:

```markdown
Create the k3d cluster and install Flux (source-controller, helm-controller,
and Flux's other standard controllers):

    task cluster:up

This is idempotent — running it again with the cluster already up just
re-applies the Flux manifests.
```

A later fix round reworded this: plain `flux install` also brings up
kustomize-controller and notification-controller, not just
source-controller/helm-controller, so the original phrasing understated
what actually gets installed (this is a docs-only wording fix — the
`scripts/cluster-up.sh` `flux install` invocation itself is unchanged, and
this task's dependency on source-controller/helm-controller specifically
being `Available` is still accurate and untouched).

- [ ] **Step 6: Commit**

```bash
git add cluster/k3d-config.yaml scripts/cluster-up.sh README.md
git commit -m "Add k3d cluster config and cluster:up script"
```

---

### Task 4: Provision the dedicated AKP instance (Terraform)

**Files:**
- Create: `terraform/01-argocd/main.tf`
- Create: `terraform/01-argocd/variables.tf`
- Create: `terraform/01-argocd/terraform.tfvars.example`
- Create: `terraform/03-clusters/main.tf`
- Create: `terraform/03-clusters/variables.tf`
- Create: `terraform/03-clusters/locals.tf`
- Create: `terraform/03-clusters/terraform.tfvars.example`
- Create: `scripts/akp-up.sh`
- Modify: `README.md` (fill in "2. Provision the Akuity Platform instance" section)

**Interfaces:**
- Consumes: the k3d cluster + `k3d-flux-to-argo` kubeconfig context from Task 3.
- Produces: a new AKP instance (name `flux-to-argo-poc`) and a registered cluster named `flux-to-argo` on that instance, with a healthy Akuity Agent running in the k3d cluster's `akuity` namespace. Task 7's `migrate.sh` targets `destination.name: flux-to-argo` on this instance; Task 9's `teardown.sh` destroys both stacks.

- [ ] **Step 1: Create `terraform/01-argocd/variables.tf`**

```hcl
variable "org_name" {
  type        = string
  description = "Akuity organization name"
}

variable "argocd_instance_name" {
  type        = string
  description = "Name of the dedicated AKP instance for this PoC"
  default     = "flux-to-argo-poc"
}

variable "argocd_version" {
  type        = string
  description = "Argo CD version to run on the instance"
  default     = "v2.13.2"
}

variable "admin_password" {
  type        = string
  description = "Local admin password for the AKP instance"
  sensitive   = true
}
```

- [ ] **Step 2: Create `terraform/01-argocd/main.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    akp = {
      source  = "akuity/akp"
      version = "~> 0.14"
    }
  }
}

provider "akp" {
  org_name = var.org_name
}

resource "akp_instance" "argocd" {
  name = var.argocd_instance_name

  argocd = {
    spec = {
      version = var.argocd_version
      instance_spec = {
        declarative_management_enabled = true
      }
    }
  }

  argocd_cm = {
    "accounts.admin" = "apiKey,login"
  }

  argocd_secret = {
    "admin.password" = bcrypt(var.admin_password)
  }

  # Known tradeoff: because argocd_secret is ignored below, changing
  # var.admin_password later and re-running `terraform apply` will NOT
  # update the live admin password -- the ignore would need to be removed
  # temporarily (or the password changed another way, e.g. via the
  # argocd/akuity CLI) for a password rotation to take effect.
  lifecycle {
    ignore_changes = [argocd_secret]
  }
}

output "instance_id" {
  value = akp_instance.argocd.id
}
```

- [ ] **Step 3: Create `terraform/01-argocd/terraform.tfvars.example`**

```
org_name       = "your-akuity-org"
admin_password = "change-me"
```

- [ ] **Step 4: Create `terraform/03-clusters/variables.tf`**

```hcl
variable "org_name" {
  type        = string
  description = "Akuity organization name"
}

variable "argocd_instance_name" {
  type        = string
  description = "Name of the AKP instance from the 01-argocd stack"
  default     = "flux-to-argo-poc"
}

variable "cluster_name" {
  type        = string
  description = "Name to register the k3d cluster under on the AKP instance"
  default     = "flux-to-argo"
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kubeconfig_context" {
  type    = string
  default = "k3d-flux-to-argo"
}
```

- [ ] **Step 5: Create `terraform/03-clusters/locals.tf`**

```hcl
locals {
  kube_config = {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
}
```

- [ ] **Step 6: Create `terraform/03-clusters/main.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    akp = {
      source  = "akuity/akp"
      version = "~> 0.14"
    }
  }
}

provider "akp" {
  org_name = var.org_name
}

data "akp_instance" "argocd" {
  name = var.argocd_instance_name
}

resource "akp_cluster" "k3d" {
  instance_id = data.akp_instance.argocd.id
  name        = var.cluster_name
  namespace   = "akuity"

  spec = {
    namespace_scoped = false
    description      = "Local k3d cluster for the flux-to-argo migration PoC"

    data = {
      size    = "small"
      project = ""
    }
  }

  kube_config    = local.kube_config
  ensure_healthy = true
}
```

- [ ] **Step 7: Create `terraform/03-clusters/terraform.tfvars.example`**

```
org_name = "your-akuity-org"
```

- [ ] **Step 8: Create `scripts/akp-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

for stack in terraform/01-argocd terraform/03-clusters; do
  echo "==> ${stack}"
  terraform -chdir="${stack}" init
  terraform -chdir="${stack}" apply -auto-approve
done
```

A later fix round changed `init -upgrade` to plain `init`: with the provider pinned to `~> 0.14` and both stacks' `.terraform.lock.hcl` now committed to the repo (see `.gitignore` — it no longer excludes lock files), `-upgrade` would silently re-resolve to the latest allowed 0.x version on every run instead of reproducing the locked/verified provider version.

- [ ] **Step 9: Make the script executable**

```bash
chmod +x scripts/akp-up.sh
```

- [ ] **Step 10: Validate the Terraform (safe, no live API calls)**

Run:
```bash
terraform -chdir=terraform/01-argocd init -backend=false
terraform -chdir=terraform/01-argocd validate
terraform -chdir=terraform/03-clusters init -backend=false
terraform -chdir=terraform/03-clusters validate
```
Expected: `Success! The configuration is valid.` for both stacks.

If `validate` reports a schema error on `akp_cluster.kube_config` or `akp_instance`'s nested `argocd`/`argocd_cm`/`argocd_secret` attributes, run `terraform providers schema -json | jq '.provider_schemas["registry.terraform.io/akuity/akp"]'` inside the relevant stack directory and adjust the HCL to match the installed provider version's actual schema — the attribute names above are believed correct but haven't been checked against a live provider install.

- [ ] **Step 11: Copy tfvars and apply for real (requires user confirmation — see Global Constraints)**

Confirm with the user before running this step; it creates a real, billable AKP instance.

```bash
cp terraform/01-argocd/terraform.tfvars.example terraform/01-argocd/terraform.tfvars
cp terraform/03-clusters/terraform.tfvars.example terraform/03-clusters/terraform.tfvars
# edit both terraform.tfvars files with your real org_name and a real admin_password
./scripts/akp-up.sh
```
Expected: both `terraform apply` runs complete with `Apply complete!`; `terraform -chdir=terraform/03-clusters output` (or checking the Akuity Portal) shows the `flux-to-argo` cluster as healthy.

- [ ] **Step 12: Fill in the README's "2. Provision the Akuity Platform instance" section**

Replace `<!-- filled in by Task 4 -->` under `### 2. Provision the Akuity Platform instance` with:

```markdown
Copy `terraform/01-argocd/terraform.tfvars.example` and
`terraform/03-clusters/terraform.tfvars.example` to `terraform.tfvars` in
each directory, fill in your `org_name` (and an `admin_password` for
01-argocd), then:

    task akp:up

This provisions a dedicated AKP instance (`flux-to-argo-poc`) and registers
the k3d cluster on it as `flux-to-argo`. It's isolated from any other AKP
instance you may already have — this PoC never touches shared instances.
```

- [ ] **Step 13: Commit**

```bash
git add terraform scripts/akp-up.sh README.md
git commit -m "Add Terraform stacks for AKP instance and cluster registration"
```

---

### Task 5: Push to GitHub, deploy the guestbook via Flux

**Files:**
- Create: `cluster/flux/guestbook-source.yaml`
- Create: `cluster/flux/guestbook-release.yaml`
- Create: `scripts/deploy-flux.sh`
- Modify: `README.md` (fill in "3. Push to GitHub and deploy via Flux" section)

**Interfaces:**
- Consumes: the chart from Task 2, the running cluster/Flux from Task 3.
- Produces: the guestbook workload running in `guestbook-demo`, owned by a Flux `HelmRelease` named `guestbook` in `flux-system`. Task 6's probe and Task 7's `migrate.sh` (which suspends this exact `HelmRelease`) depend on this existing.

- [ ] **Step 1: Push this repo to GitHub (requires user confirmation — see Global Constraints)**

Confirm with the user before running; this creates a real public repo. Skip if `adamancini/flux-to-argo` already exists on GitHub.

```bash
gh repo create adamancini/flux-to-argo --public --source=. --remote=origin
git push -u origin main
```

- [ ] **Step 2: Create `cluster/flux/guestbook-source.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: guestbook
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/adamancini/flux-to-argo
  ref:
    branch: main
```

- [ ] **Step 3: Create `cluster/flux/guestbook-release.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: guestbook
  namespace: flux-system
spec:
  interval: 1m
  targetNamespace: guestbook-demo
  install:
    createNamespace: true
  chart:
    spec:
      chart: chart/guestbook
      sourceRef:
        kind: GitRepository
        name: guestbook
        namespace: flux-system
```

- [ ] **Step 4: Create `scripts/deploy-flux.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f cluster/flux/guestbook-source.yaml
kubectl apply -f cluster/flux/guestbook-release.yaml

kubectl wait --for=condition=ready --timeout=180s \
  -n flux-system helmrelease/guestbook

kubectl wait --for=condition=available --timeout=180s \
  -n guestbook-demo deployment/frontend deployment/redis-leader deployment/redis-follower
```

- [ ] **Step 5: Make the script executable**

```bash
chmod +x scripts/deploy-flux.sh
```

- [ ] **Step 6: Run it and verify the guestbook comes up under Flux**

Run:
```bash
./scripts/deploy-flux.sh
kubectl get helmrelease -n flux-system guestbook
kubectl get pods -n guestbook-demo
```
Expected: `HelmRelease` shows `READY=True`; all pods in `guestbook-demo` (`frontend`, `redis-leader`, two `redis-follower`) show `Running` and `1/1` ready.

- [ ] **Step 7: Fill in the README's "3. Push to GitHub and deploy via Flux" section**

Replace `<!-- filled in by Task 5 -->` under `### 3. Push to GitHub and deploy via Flux` with:

```markdown
One-time: push this repo to GitHub so Flux (and later, ArgoCD) can pull the
chart from it.

    gh repo create adamancini/flux-to-argo --public --source=. --remote=origin
    git push -u origin main

Then deploy the guestbook via a Flux `GitRepository` + `HelmRelease`:

    task deploy:flux
```

- [ ] **Step 8: Commit**

```bash
git add cluster/flux scripts/deploy-flux.sh README.md
git commit -m "Deploy guestbook via Flux GitRepository and HelmRelease"
```

---

### Task 6: Verification probe (availability, pod stability, canary entry)

**Files:**
- Create: `scripts/verify-start.sh`
- Create: `scripts/verify-report.sh`
- Modify: `README.md` (fill in "4. Start the verification probe" section)

**Interfaces:**
- Consumes: the guestbook running in `guestbook-demo` from Task 5 (any controller — Flux or, later, ArgoCD).
- Produces: `.verify/probe.log` (timestamped PASS/FAIL lines), `.verify/pods.log` (JSON-lines pod snapshots), `.verify/canary.txt` (the canary value written), `.verify/probe.pid` and `.verify/port-forward.pid` (background process IDs `verify-report.sh` uses to stop things). Task 7's `migrate.sh` is meant to run while this probe is active.

- [ ] **Step 1: Create `scripts/verify-start.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="guestbook-demo"
LOGDIR=".verify"
PROBE_LOG="${LOGDIR}/probe.log"
PODS_LOG="${LOGDIR}/pods.log"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

mkdir -p "${LOGDIR}"

if [[ -f "${PIDFILE}" ]]; then
  echo "Probe already running (pid $(cat "${PIDFILE}")). Run 'task verify:report' first." >&2
  exit 1
fi

: > "${PROBE_LOG}"
: > "${PODS_LOG}"

cleanup_port_forward() {
  if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then
    kill "$(cat "${PORT_FORWARD_PIDFILE}")" 2>/dev/null || true
    rm -f "${PORT_FORWARD_PIDFILE}"
  fi
}

kubectl -n "${NAMESPACE}" port-forward svc/frontend 8080:80 \
  >"${LOGDIR}/port-forward.log" 2>&1 &
echo $! > "${PORT_FORWARD_PIDFILE}"
trap cleanup_port_forward ERR
sleep 2

CANARY="canary-$(date +%s)-$$"
echo "${CANARY}" > "${LOGDIR}/canary.txt"
curl -sf "http://localhost:8080/guestbook.php?cmd=set&key=canary&value=${CANARY}" >/dev/null

(
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if curl -sf -o /dev/null "http://localhost:8080/"; then
      echo "${ts} PASS" >> "${PROBE_LOG}"
    else
      echo "${ts} FAIL" >> "${PROBE_LOG}"
    fi

    kubectl -n "${NAMESPACE}" get pods -l app=guestbook -o json 2>/dev/null \
      | jq -c --arg ts "${ts}" \
        '.items[] | {ts: $ts, name: .metadata.name, created: .metadata.creationTimestamp, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}' \
      >> "${PODS_LOG}"
    kubectl -n "${NAMESPACE}" get pods -l app=redis -o json 2>/dev/null \
      | jq -c --arg ts "${ts}" \
        '.items[] | {ts: $ts, name: .metadata.name, created: .metadata.creationTimestamp, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}' \
      >> "${PODS_LOG}"

    sleep 1
  done
) &
echo $! > "${PIDFILE}"
trap - ERR

echo "Probe started (pid $(cat "${PIDFILE}")). Logs: ${PROBE_LOG}, ${PODS_LOG}"
```

Note: `cleanup_port_forward` is wired to an `ERR` trap (not `EXIT`) so that a failure partway through startup (e.g. the initial canary `curl` failing) kills the just-started `port-forward` instead of leaking it — the trap is cleared (`trap - ERR`) once the background probe loop is successfully launched, since from that point ownership of stopping things belongs to `verify-report.sh`.

- [ ] **Step 2: Create `scripts/verify-report.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="guestbook-demo"
LOGDIR=".verify"
PROBE_LOG="${LOGDIR}/probe.log"
PODS_LOG="${LOGDIR}/pods.log"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then
  kill "$(cat "${PORT_FORWARD_PIDFILE}")" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PIDFILE}"
fi

total=$(wc -l < "${PROBE_LOG}" | tr -d ' ')
failures=$(grep -c FAIL "${PROBE_LOG}" || true)

echo "== Availability =="
echo "requests: ${total}, failures: ${failures}"

echo "== Pod restart counts (max seen per pod) =="
jq -s '
  group_by(.name)
  | map({name: .[0].name, max_restarts: (map(.restarts) | max)})
' "${PODS_LOG}"

echo "== Pod identity stability (distinct pod names per component; should equal replica count) =="
jq -r '.name' "${PODS_LOG}" | sort -u | sed -E 's/-[a-z0-9]+-[a-z0-9]{5}$//' | sort | uniq -c

echo "== Canary entry =="
CANARY="$(cat "${LOGDIR}/canary.txt")"
kubectl -n "${NAMESPACE}" port-forward svc/frontend 8081:80 >/dev/null 2>&1 &
FWD_PID=$!
trap 'kill "${FWD_PID}" 2>/dev/null || true' EXIT
sleep 2
RESULT="$(curl -sf "http://localhost:8081/guestbook.php?cmd=get&key=canary" || echo 'UNREACHABLE')"

if [[ "${RESULT}" == *"${CANARY}"* ]]; then
  echo "canary entry '${CANARY}' PRESENT"
else
  echo "canary entry '${CANARY}' MISSING (got: ${RESULT})"
fi

if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT: PASS (zero failed requests)"
else
  echo "RESULT: FAIL (${failures} failed requests)"
fi
```

Note: the report's own port-forward (`FWD_PID`) is cleaned up via an `EXIT` trap rather than an explicit `kill` after the `curl`, so it's still killed even if the `curl` step or anything after it exits unexpectedly.

- [ ] **Step 3: Make both scripts executable**

```bash
chmod +x scripts/verify-start.sh scripts/verify-report.sh
```

- [ ] **Step 4: Run a short probe cycle against the Flux-managed guestbook and verify it reports cleanly**

Run:
```bash
./scripts/verify-start.sh
sleep 10
./scripts/verify-report.sh
```
Expected: `requests: 10, failures: 0` (approximately — timing may vary by a request or two); every pod's `max_restarts` is `0`; the identity-stability count for `frontend` is `1`, `redis-leader` is `1`, `redis-follower` is `2`; canary entry reports `PRESENT`; final line `RESULT: PASS`.

- [ ] **Step 5: Fill in the README's "4. Start the verification probe" section**

Replace `<!-- filled in by Task 6 -->` under `### 4. Start the verification probe` with:

```markdown
Before migrating, start the background probe — it curls the frontend once a
second, snapshots pod restart counts and identities, and writes a canary
guestbook entry to later confirm redis-leader was never recreated:

    task verify:start

Leave it running through the migration step. Stop it and see the results
with:

    task verify:report
```

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-start.sh scripts/verify-report.sh README.md
git commit -m "Add availability/stability verification probe"
```

---

### Task 7: ArgoCD Application manifest and cutover script

**Files:**
- Create: `cluster/argocd/guestbook-app.yaml`
- Create: `scripts/migrate.sh`
- Modify: `README.md` (fill in "5. Migrate to ArgoCD" section)

**Interfaces:**
- Consumes: the AKP instance + registered `flux-to-argo` cluster from Task 4, the Flux-managed guestbook from Task 5, the GitHub repo from Task 5.
- Produces: an ArgoCD `Application` named `guestbook` on the AKP instance, and — once `migrate.sh` runs — the Flux `HelmRelease` `guestbook` in a `Suspended` state (not deleted). Task 8's `cleanup-flux.sh` deletes that suspended `HelmRelease`.

- [ ] **Step 1: Create `cluster/argocd/guestbook-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/adamancini/flux-to-argo
    targetRevision: main
    path: chart/guestbook
  destination:
    name: flux-to-argo
    namespace: guestbook-demo
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
  # If the chart ever adds other resource kinds that get adopted from an
  # existing Flux-managed release (e.g. ConfigMap, Secret), add a matching
  # ignoreDifferences entry for the tracking-id annotation on that kind too
  # -- otherwise its first-adoption diff will look like drift.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /metadata/annotations/argocd.argoproj.io~1tracking-id
    - group: ""
      kind: Service
      jsonPointers:
        - /metadata/annotations/argocd.argoproj.io~1tracking-id
```

`ignoreDifferences` is required here, not optional polish: ArgoCD unconditionally stamps a `argocd.argoproj.io/tracking-id` annotation onto every resource it adopts that no other ArgoCD Application has managed before. Since Flux created these resources, `argocd app diff` will show this annotation as an addition on the very first check, before any sync has run — with no CLI flag to exclude it. Without `ignoreDifferences`, `migrate.sh`'s diff-based safety gate (Step 2) would abort on every first-time cutover, mistaking ArgoCD's own adoption bookkeeping for real drift. Genuine drift (an actual image tag, replica count, or config difference) still shows up and still aborts the migration — only this one known, expected, per-adoption annotation is excluded from the comparison.

A later fix round changed `syncPolicy: {}` to add `syncOptions: [CreateNamespace=true]`, so the Application is self-sufficient if ever applied to a fresh cluster where Flux hasn't already created the `guestbook-demo` namespace (in this PoC's actual run, Flux always creates it first via `install.createNamespace: true`, so this had no effect on the live migration — it's a correctness fix for future/standalone use). It also added the comment above `ignoreDifferences` about extending it if the chart gains other adopted resource kinds.

- [ ] **Step 2: Create `scripts/migrate.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="guestbook"

echo "==> Creating ArgoCD Application (manual sync)"
argocd app create -f cluster/argocd/guestbook-app.yaml --upsert

echo "==> Diffing before touching Flux"
# argocd app diff exits non-zero both for real drift AND for unrelated
# failures (not logged in, unreachable API, etc.) -- this check can't tell
# the two apart, so the message below covers both.
if ! argocd app diff "${APP_NAME}"; then
  echo "argocd app diff reported a difference (or failed to run — check you're logged in with 'argocd login'). Resolve before suspending Flux. Aborting." >&2
  exit 1
fi

echo "==> Suspending the Flux HelmRelease"
flux suspend helmrelease guestbook -n flux-system

echo "==> Syncing the ArgoCD Application"
argocd app sync "${APP_NAME}"
argocd app wait "${APP_NAME}" --health --timeout 180

echo "==> Promoting to automated sync with self-heal"
argocd app set "${APP_NAME}" --sync-policy automated --auto-prune --self-heal

echo "==> Cutover complete. Flux HelmRelease is suspended (not deleted)."
```

A later fix round reworded the diff-check error message: the original ("Diff shows drift — resolve before suspending Flux. Aborting.") implied the failure was always real drift, but `argocd app diff` also exits non-zero for unrelated problems like not being logged in or API connectivity issues — the new message calls that out explicitly.

- [ ] **Step 3: Make the script executable**

```bash
chmod +x scripts/migrate.sh
```

- [ ] **Step 4: Run the cutover while the probe is active, and verify no disruption**

Run (with `task verify:start` already running from Task 6, Step 4):
```bash
argocd login <your-akp-instance-argocd-url> # one-time per shell session
./scripts/migrate.sh
kubectl get helmrelease -n flux-system guestbook
kubectl get pods -n guestbook-demo
```
Expected: `migrate.sh` completes through "Cutover complete"; `kubectl get helmrelease` shows `SUSPENDED=True`; all guestbook pods are still `Running` with the same names/ages they had before `migrate.sh` ran (compare against the pod list from Task 5, Step 6 or the running `verify-start.sh` pod log).

- [ ] **Step 5: Fill in the README's "5. Migrate to ArgoCD" section**

Replace `<!-- filled in by Task 7 -->` under `### 5. Migrate to ArgoCD` with:

```markdown
With the probe running (previous step), log in to the AKP instance's ArgoCD
API once per shell session:

    argocd login <your-akp-instance-argocd-url>

Then run the cutover:

    task migrate

This creates the ArgoCD `Application`, diffs it against what Flux already
deployed (aborting if there's unexpected drift), suspends the Flux
`HelmRelease` (not deleted — this is your rollback point), syncs the
`Application` in place, and promotes it to automated sync with self-heal.
Because resource identity (kind/namespace/name) never changes, this is an
in-place update, not a delete-and-recreate — watch `task verify:start`'s
logs (or run `task verify:report` after) to confirm zero downtime.

**Rollback**, at any point before "Cutover complete" prints: `flux resume
helmrelease guestbook -n flux-system` and `argocd app delete guestbook`.
```

- [ ] **Step 6: Commit**

```bash
git add cluster/argocd scripts/migrate.sh README.md
git commit -m "Add ArgoCD Application manifest and migration cutover script"
```

---

### Task 8: Clean up the suspended Flux objects

**Files:**
- Create: `scripts/cleanup-flux.sh`
- Modify: `README.md` (fill in "6. Clean up Flux" section)

**Interfaces:**
- Consumes: the suspended `HelmRelease`/`GitRepository` from Task 7's `migrate.sh`.
- Produces: `flux-system` with no `guestbook` `HelmRelease`/`GitRepository`, and no orphaned Helm release `Secret`.

- [ ] **Step 1: Create `scripts/cleanup-flux.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# The HelmRelease never set spec.storageNamespace or spec.releaseName, so
# Flux's helm-controller used its defaults: the release Secret lives in the
# HelmRelease's own namespace (flux-system), not targetNamespace
# (guestbook-demo), under the release name "<targetNamespace>-<chart>"
# (guestbook-demo-guestbook) rather than the chart name.
FLUX_NAMESPACE="flux-system"
HELM_RELEASE_NAME="guestbook-demo-guestbook"

# Guard against running this out of order (before 'task migrate'): if the
# HelmRelease isn't suspended, Flux's helm-controller still owns the release
# and deleting the HelmRelease would trigger its own Helm uninstall, taking
# down the live guestbook instead of just removing dead Flux bookkeeping.
if [[ "$(kubectl get helmrelease guestbook -n "${FLUX_NAMESPACE}" -o jsonpath='{.spec.suspend}' 2>/dev/null)" != "true" ]]; then
  echo "HelmRelease 'guestbook' is not suspended — run 'task migrate' first. Aborting." >&2
  exit 1
fi

echo "==> Deleting suspended Flux objects"
kubectl delete helmrelease guestbook -n "${FLUX_NAMESPACE}" --ignore-not-found
kubectl delete gitrepository guestbook -n "${FLUX_NAMESPACE}" --ignore-not-found

echo "==> Removing orphaned Helm release secret"
kubectl delete secret -n "${FLUX_NAMESPACE}" \
  -l "owner=helm,name=${HELM_RELEASE_NAME}" --ignore-not-found
```

This deviates from an earlier draft of this step, which assumed the Helm release Secret would be in `guestbook-demo` under the release name `guestbook` — that assumption was wrong. Flux's helm-controller defaults (unset `storageNamespace`/`releaseName`) put it in `flux-system` under `guestbook-demo-guestbook`, discovered by inspecting the live cluster during implementation.

A later fix round added the `spec.suspend` precondition guard above (to stop `task cleanup:flux` from being run before `task migrate` and accidentally uninstalling the live guestbook via Flux's own Helm uninstall path), and switched the inline `flux-system` literals on the `kubectl delete helmrelease`/`kubectl delete gitrepository` lines to reuse the already-declared `${FLUX_NAMESPACE}` variable.

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/cleanup-flux.sh
```

- [ ] **Step 3: Run it and verify Flux's objects and the Helm secret are gone, while the app is untouched**

Run:
```bash
./scripts/cleanup-flux.sh
kubectl get helmrelease,gitrepository -n flux-system
kubectl get secret -n guestbook-demo -l owner=helm,name=guestbook
kubectl get pods -n guestbook-demo
```
Expected: the first two commands show no `guestbook` resources (empty or "No resources found"); guestbook pods are still `Running` and unaffected (ArgoCD, not Flux, owns them now).

- [ ] **Step 4: Fill in the README's "6. Clean up Flux" section**

Replace `<!-- filled in by Task 8 -->` under `### 6. Clean up Flux` with:

```markdown
Once the ArgoCD `Application` is healthy and automated, remove the
now-suspended Flux objects and the Helm release secret Flux's
helm-controller created (ArgoCD doesn't use Helm release secrets, so this
is dead metadata, not a live dependency):

    task cleanup:flux
```

- [ ] **Step 5: Commit**

```bash
git add scripts/cleanup-flux.sh README.md
git commit -m "Add Flux cleanup script"
```

---

### Task 9: Teardown

**Files:**
- Create: `scripts/teardown.sh`
- Modify: `README.md` (fill in "7. Tear down" section)

**Interfaces:**
- Consumes: the k3d cluster from Task 3, the Terraform-managed AKP instance/cluster registration from Task 4.
- Produces: no k3d cluster, no AKP instance, no `.verify/` directory. Terminal task — nothing downstream depends on it.

- [ ] **Step 1: Create `scripts/teardown.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

LOGDIR=".verify"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

echo "==> Stopping any still-running verification probe"
if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then
  kill "$(cat "${PORT_FORWARD_PIDFILE}")" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PIDFILE}"
fi

echo "==> Destroying Terraform-managed AKP resources"
terraform -chdir=terraform/03-clusters destroy -auto-approve \
  || echo "WARNING: terraform/03-clusters destroy failed, continuing" >&2
terraform -chdir=terraform/01-argocd destroy -auto-approve \
  || echo "WARNING: terraform/01-argocd destroy failed, continuing" >&2

echo "==> Deleting k3d cluster"
k3d cluster delete flux-to-argo \
  || echo "WARNING: k3d cluster delete failed, continuing" >&2

rm -rf .verify
```

A later fix round added two things: (1) best-effort probe cleanup up front (mirroring `verify-report.sh`'s pidfile-kill pattern), since `rm -rf .verify` alone could leave a background `kubectl port-forward` and curl loop running if `task verify:report` was never run before teardown; (2) `|| echo "WARNING: ... continuing" >&2` on each `terraform destroy` and the `k3d cluster delete`, so a failure in one step (e.g. `03-clusters destroy`) doesn't abort the script under `set -e` before the remaining cleanup steps get a chance to run.

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/teardown.sh
```

- [ ] **Step 3: Run it and verify everything is gone (requires user confirmation — see Global Constraints)**

Confirm with the user before running; this destroys the real AKP instance created in Task 4.

Run:
```bash
./scripts/teardown.sh
k3d cluster list
```
Expected: `terraform destroy` completes with `Destroy complete!` for both stacks; `k3d cluster list` no longer lists `flux-to-argo`; `.verify/` no longer exists.

- [ ] **Step 4: Fill in the README's "7. Tear down" section**

Replace `<!-- filled in by Task 9 -->` under `### 7. Tear down` with:

```markdown
Destroy the AKP instance and delete the k3d cluster:

    task down
```

- [ ] **Step 5: Commit**

```bash
git add scripts/teardown.sh README.md
git commit -m "Add teardown script"
```
