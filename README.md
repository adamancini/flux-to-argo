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

One-time: push this repo to GitHub so Flux (and later, ArgoCD) can pull the
chart from it.

    gh repo create adamancini/flux-to-argo --public --source=. --remote=origin
    git push -u origin HEAD:main

Then deploy the guestbook via a Flux `GitRepository` + `HelmRelease`:

    task deploy:flux

### 4. Start the verification probe

Before migrating, start the background probe — it curls the frontend once a
second, snapshots pod restart counts and identities, and writes a canary
guestbook entry to later confirm redis-leader was never recreated:

    task verify:start

Leave it running through the migration step. Stop it and see the results
with:

    task verify:report

### 5. Migrate to ArgoCD

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

### 6. Clean up Flux

Once the ArgoCD `Application` is healthy and automated, remove the
now-suspended Flux objects and the Helm release secret Flux's
helm-controller created (ArgoCD doesn't use Helm release secrets, so this
is dead metadata, not a live dependency):

    task cleanup:flux

### 7. Tear down

Destroy the AKP instance and delete the k3d cluster:

    task down
