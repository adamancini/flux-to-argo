# flux-to-argo

A small, fully-scripted proof of concept: migrate a classic 3-tier guestbook
app from a Flux `HelmRelease` to an Akuity-hosted ArgoCD `Application`,
without downtime.

See [the design spec](docs/superpowers/specs/2026-08-10-flux-to-argo-poc-design.md)
for the full rationale.

## Prerequisites

- `docker` (k3d runs on it), `k3d`, `kubectl`, `helm` (v3, used for local
  chart linting — not invoked by any script here), `flux` CLI, `terraform`
  (>= 1.5), `argocd` CLI, `gh` CLI (authenticated), `jq`, `curl`, `task`
  (go-task)
- `AKUITY_API_KEY_ID` / `AKUITY_API_KEY_SECRET` set in your environment

## Walkthrough

### 1. Cluster + Flux

Create the k3d cluster and install Flux (source-controller, helm-controller,
and Flux's other standard controllers):

    task cluster:up

This is idempotent — running it again with the cluster already up just
re-applies the Flux manifests.

### 2. Push to GitHub and deploy via Flux

One-time: push this repo to GitHub so Flux (and later, ArgoCD) can pull the
chart from it.

    gh repo create adamancini/flux-to-argo --public --source=. --remote=origin
    git push -u origin HEAD:main

If you're forking this repo rather than using `adamancini/flux-to-argo`
directly, substitute your own repo name above and update `repoURL` in both
`cluster/flux/guestbook-source.yaml` and `cluster/argocd/guestbook-app.yaml`
to match.

Then deploy the guestbook via a Flux `GitRepository` + `HelmRelease`:

    task deploy:flux

At this point, check `kubectl get pods -n guestbook-demo` and
`flux get helmrelease -n flux-system` — the guestbook is live and entirely
Flux-managed. No AKP instance exists yet; that's deliberate, so you can see
the "before" state of the migration clearly before ArgoCD enters the
picture at all.

### 3. Provision the Akuity Platform instance

Copy `terraform/01-argocd/terraform.tfvars.example` and
`terraform/03-clusters/terraform.tfvars.example` to `terraform.tfvars` in
each directory, fill in your `org_name` (and an `admin_password` for
01-argocd), then:

    task akp:up

This provisions a dedicated AKP instance (`flux-to-argo-poc`) and registers
the k3d cluster on it as `flux-to-argo`. It's isolated from any other AKP
instance you may already have — this PoC never touches shared instances.

### 4. Start the verification probe

Before migrating, start the background probe — it curls the frontend once a
second, snapshots pod restart counts and identities, and writes a canary
guestbook entry to later confirm redis-leader was never recreated:

    task verify:start

Leave it running through the whole migration (next section) and, optionally,
the Flux cleanup after that — stopping it early would cut the probe's
coverage of the cutover window it's meant to observe. Don't run
`task verify:report` yet; that comes after the migration step below.

### 5. Migrate to ArgoCD

With the probe running (previous step), log in to the AKP instance's ArgoCD
API once per shell session:

    argocd login <your-akp-instance-argocd-url> --grpc-web --username admin

Find `<your-akp-instance-argocd-url>` via
`akuity argocd instance get <instance-name> -o yaml` and look for the
`hostname` field, or from the Akuity Portal UI.

Then run the cutover:

    task migrate

This creates the ArgoCD `Application`, diffs it against what Flux already
deployed (aborting if there's unexpected drift), suspends the Flux
`HelmRelease` (not deleted — this is your rollback point), syncs the
`Application` in place, and promotes it to automated sync with self-heal.
Because resource identity (kind/namespace/name) never changes, this is an
in-place update, not a delete-and-recreate. Once the cutover completes, run
`task verify:report` to stop the probe and print the pass/fail summary —
that's the point in the walkthrough where those results are meant to appear
(see the previous section).

**Rollback**, at any point before "Cutover complete" prints:

    flux resume helmrelease guestbook -n flux-system
    argocd app delete guestbook --cascade=false

`--cascade=false` is not optional here: `argocd app delete` defaults to
`--cascade=true`, which deletes every resource the Application tracks
(frontend/redis-leader/redis-follower Deployments and Services) along with
the Application object itself — taking down the live guestbook instead of
just removing ArgoCD's bookkeeping and handing control back to Flux. If you
forget the flag and the workload disappears,
`flux reconcile helmrelease guestbook -n flux-system --force` reinstalls it
(you'll lose whatever in-memory Redis state existed, including the canary
entry, since the Deployments were genuinely deleted and recreated, not just
made unreachable).

### 6. Clean up Flux

Once the ArgoCD `Application` is healthy and automated, remove the
now-suspended Flux objects and the Helm release secret Flux's
helm-controller created (ArgoCD doesn't use Helm release secrets, so this
is dead metadata, not a live dependency):

    task cleanup:flux

### 7. Tear down

Destroy the AKP instance and delete the k3d cluster:

    task down
