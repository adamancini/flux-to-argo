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

Create the k3d cluster and install Flux's source-controller and
helm-controller:

    task cluster:up

This is idempotent — running it again with the cluster already up just
re-applies the Flux manifests.

### 2. Provision the Akuity Platform instance

Copy `terraform/01-argocd/terraform.tfvars.example` and
`terraform/03-clusters/terraform.tfvars.example` to `terraform.tfvars` in
each directory, fill in your `org_name` (and an `admin_password` for
01-argocd), then:

    task akp:up

This provisions a dedicated AKP instance (`flux-to-argo-poc`) and registers
the k3d cluster on it as `flux-to-argo`. It's isolated from any other AKP
instance you may already have — this PoC never touches shared instances.

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
