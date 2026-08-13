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

### 3. Start the verification probe

Start the background probe now, before AKP even exists — it curls the
frontend once a second, snapshots pod restart counts and identities, and
writes a canary guestbook entry to later confirm redis-leader was never
recreated:

    task verify:start

In a second terminal, watch it happen live:

    task verify:watch

That tails the probe's log files and continuously watches the
`guestbook-demo` pods and the Flux `HelmRelease` for changes (plus polling
the ArgoCD `Application` once it exists later on) — leave it running
alongside everything below so you can see, in real time, that provisioning
AKP and migrating are genuinely non-disruptive, not just after the fact
from a summary.

Leave `verify:start`'s probe running through AKP provisioning, the whole
migration (two sections down), and, optionally, the Flux cleanup after that
— stopping it early would cut its coverage of the window it's meant to
observe. Don't run `task verify:report` yet; that comes after the migration
step below.

### 4. Provision the Akuity Platform instance

Copy `terraform/01-argocd/terraform.tfvars.example` and
`terraform/03-clusters/terraform.tfvars.example` to `terraform.tfvars` in
each directory, fill in your `org_name` (and an `admin_password` for
01-argocd), then:

    task akp:up

This provisions a dedicated AKP instance (`flux-to-argo-poc`) and registers
the k3d cluster on it as `flux-to-argo`. It's isolated from any other AKP
instance you may already have — this PoC never touches shared instances.
With the probe (and `verify:watch`, if you started it) still running, this
is a good point to confirm nothing about standing up AKP disturbed the
Flux-managed guestbook either.

As soon as the instance is created, `task akp:up` prints its URL and a
ready-to-copy login command, e.g.:

    ArgoCD instance is up: https://<instance-id>.cd.akuity.cloud
    Log in with:
      argocd login <instance-id>.cd.akuity.cloud --grpc-web --username admin
    (password is in terraform/01-argocd/terraform.tfvars)

### 5. Migrate to ArgoCD

With the probe still running (started two sections up), log in to the AKP
instance's ArgoCD API once per shell session using the command
`task akp:up` printed in the previous section:

    argocd login <instance-id>.cd.akuity.cloud --grpc-web --username admin

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
(see "3. Start the verification probe" above). If `verify:watch` is still
running in your second terminal, stop it too (Ctrl-C) once you've reviewed
the report.

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

## Bonus scenario: Helm lookup & hooks pitfalls

A second, independent scenario on the same cluster and AKP instance, showing
two pitfalls that hit a "helm-first" chart specifically when it's deployed
via ArgoCD instead of `helm install`/`helm upgrade`, and how to refactor a
chart to avoid them. See
[the design spec](docs/superpowers/specs/2026-08-11-helm-lookup-hooks-demo-design.md)
for the full rationale, including real evidence from production chart fixes.

### 1. Deploy the anti-pattern chart via Flux

    task adminapp:deploy-flux

Deploys `chart/adminapp-helmfirst` — a tiny app with a `lookup`-based secret
and a non-idempotent `post-install` hook Job — into the `adminapp-demo`
namespace. Under Flux's real Helm SDK installs/upgrades, both work exactly as
a helm-first developer would expect: the secret is stable across reconciles,
and the hook only ever runs once.

### 2. Adopt it under ArgoCD and watch both pitfalls surface

    task adminapp:break

Creates an ArgoCD `Application` pointed at the *same* `chart/adminapp-helmfirst`
path, suspends Flux, and syncs it twice. `argocd` renders with `helm
template`, not `helm install`/`upgrade`, so: the `session-secret` changes on
every single sync (Pitfall 1 — `lookup` always returns empty there), and the
`post-install` hook Job — which already ran once under Flux — gets
re-triggered on ArgoCD's very first sync, hitting a real SQLite `UNIQUE
constraint failed` error on the second insert (Pitfall 2), then blocking the
next sync entirely because the failed Job was never cleaned up.

### 3. Refactor and repoint at the fixed chart

    task adminapp:fix

Repoints the same `Application` at `chart/adminapp-gitops` — the secret now
resolves with precedence **explicit value > existing in-cluster value >
random** (set here via `--helm-set sessionSecret=...`, in real usage managed
with SOPS/Sealed Secrets), and the hook Job is now a plain, statically-named,
idempotent resource instead of a Helm hook. Two syncs in a row show the
secret staying put and the Job completing cleanly both times. The old broken
hook Job from `adminapp-helmfirst` stays behind, though — ArgoCD's prune only
applies to normal tracked resources, not hook resources, whose lifecycle is
governed solely by `helm.sh/hook-delete-policy`; since that Job Failed rather
than Succeeded, its `hook-succeeded` policy never fires. It's inert and gets
removed along with everything else once `task adminapp:cleanup`/`task down`
deletes the namespace.

### 4. A third-party chart you can't edit

    task adminapp:vendored

`chart/vendored-widget-kustomize/vendored-widget` simulates a chart you pulled from someone else's Helm
repo — same lookup/hooks anti-patterns, but off-limits to edit or fork.
`chart/vendored-widget-kustomize/` inflates it with Kustomize's
`helmCharts` generator and patches its Job's `helm.sh/hook*` annotations to
`argocd.argoproj.io/hook*` equivalents at render time (needs
`kustomize.buildOptions: --enable-helm` on the AKP instance — see
`terraform/01-argocd/main.tf`). The script diffs the chart's raw output
against what ArgoCD actually applied to show the rewrite took effect without
touching the chart's source. This fixes ArgoCD's *lifecycle mapping* of the
hook; it does not and cannot fix the vendored Job's own non-idempotent SQL —
that's still out of our hands for code we don't own.
