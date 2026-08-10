# flux-to-argo

A small, fully-scripted proof of concept: migrate a classic 3-tier guestbook
app from a Flux `HelmRelease` to an Akuity-hosted ArgoCD `Application`,
without downtime.

See [the design spec](docs/superpowers/specs/2026-08-10-flux-to-argo-poc-design.md)
for the full rationale.

## Prerequisites

- `kind`, `kubectl`, `helm` (v3), `flux` CLI, `terraform` (>= 1.5), `argocd`
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
