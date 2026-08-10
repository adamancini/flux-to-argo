# Zero-Downtime Flux → ArgoCD Migration PoC

**Date:** 2026-08-10
**Status:** Approved

## Purpose

Demonstrate, on a small self-contained example, how a Kubernetes service managed by a Flux `HelmRelease` can be migrated to an Akuity-hosted ArgoCD `Application` without downtime. The proof is a classic 3-tier guestbook app; the point is the migration mechanics, not the app itself.

## Non-goals

- Not a general-purpose Flux→ArgoCD migration tool. This is one worked example, scripted for repeatability, not a reusable library.
- Not testing scale, HA, or multi-cluster fleets. One kind cluster, one small app.
- Not covering ApplicationSets, Kargo, or promotion pipelines — those are out of scope for this PoC.

## Architecture

One disposable **kind** cluster plus one dedicated **Akuity Platform (AKP)** instance:

- **kind cluster** (`flux-to-argo`) — runs Flux (source-controller, helm-controller) in `flux-system`, and the guestbook workload in `guestbook-demo`. No in-cluster ArgoCD.
- **AKP instance** — a new instance provisioned just for this PoC via the `akuity` CLI, isolated from any existing shared AKP instance/demo environment. Its hosted ArgoCD control plane (repo-server, application-controller, API) runs in Akuity's cloud, not in the kind cluster.
- **Cluster registration** — the kind cluster is registered to the new AKP instance as a workload cluster via `akuity cluster add`, which generates agent-install manifests applied to kind so the hosted control plane can reach it.
- **GitHub repo** — `adamancini/flux-to-argo` (this repo), public. Both Flux's `GitRepository`/`HelmRelease` and the AKP-hosted `Application` pull the same `chart/guestbook/` from this repo over HTTPS. This matters specifically because the AKP repo-server runs off-cluster in Akuity's cloud — it cannot reach anything sitting only inside kind's local Docker network (e.g., a local OCI registry), so the chart source must be reachable independent of the kind cluster's network.

## The app

Classic 3-tier guestbook, as one umbrella Helm chart at `chart/guestbook/`:

- `frontend` — Deployment (1 replica) + Service
- `redis-leader` — Deployment (1 replica) + Service
- `redis-follower` — Deployment (2 replicas) + Service

No PersistentVolumes. This is deliberate: with no persistence, an accidental pod recreation during migration would visibly lose any guestbook entry written before cutover, so "the canary entry is still there after migration" is a strong, cheap tripwire for hidden data-plane disruption.

## Migration flow

1. **`task cluster:up`** — create the kind cluster, `flux install` (plain manifest install, no bootstrap-to-self-repo).
2. **`task akp:up`** — `akuity` CLI creates the new dedicated AKP instance and registers the kind cluster as a workload cluster.
3. **Push to GitHub** — chart and Flux/ArgoCD manifests pushed to `adamancini/flux-to-argo`.
4. **`task deploy:flux`** — apply Flux `GitRepository` + `HelmRelease` for the guestbook chart. Flux's helm-controller installs the 3-tier app into `guestbook-demo` and owns it (including creating a real Helm release Secret, since helm-controller calls the Helm SDK directly).
5. **`task verify:start`** — start a background verification probe (see Verification below) that runs continuously through the rest of the flow.
6. **`task migrate`** — the cutover, as one scripted sequence:
   a. Create the AKP `Application` from the manifest at `cluster/argocd/guestbook-app.yaml` (same chart/values/namespace as the Flux `HelmRelease`, sync policy **manual**, `Prune=false`), applied against the AKP instance via the `akuity`/`argocd` CLI.
   b. Run an `argocd app diff` equivalent against the AKP instance — expect near-zero drift, since it's the same rendered manifests Flux already applied.
   c. `flux suspend helmrelease guestbook -n guestbook-demo` — Flux stops reconciling. Nothing is deleted at this step; suspension is the actual point of no return we can still cleanly reverse.
   d. Sync the AKP `Application`. Because resource identity (kind/namespace/name) is unchanged and the diff was near-zero, ArgoCD performs an in-place apply, not a delete+recreate — Services keep their ClusterIPs, pods are not touched unless the diff surfaces a real change.
   e. Flip the `Application` to automated sync + self-heal once the sync is confirmed healthy.
7. **`task cleanup:flux`** — delete the now-suspended Flux `HelmRelease`/`GitRepository`, and the orphaned Helm release Secret Flux's helm-controller created. ArgoCD does not use Helm release Secrets — it renders and applies templates directly — so this Secret is dead metadata once Flux is gone, not a live dependency.
8. **`task verify:report`** — stop the probe and print a pass/fail summary.
9. **`task down`** — tear down the kind cluster and delete the AKP instance.

### Rollback

Before step 6d completes, rollback is just `flux resume helmrelease guestbook` plus deleting the AKP `Application`. This falls out of the sequencing (suspend, don't delete, until cleanup) rather than requiring separate rollback code.

## Verification (the "no downtime" proof)

A background probe runs continuously from step 5 through step 6, logging to a timestamped file:

- **Availability**: a curl loop against the guestbook frontend Service, once per second, recording pass/fail and latency.
- **Workload stability**: periodic snapshots (every few seconds) of pod restart-counts and creation-timestamps for `frontend`, `redis-leader`, and `redis-follower` — any change during the cutover window indicates an unwanted delete+recreate.
- **Data continuity**: a canary guestbook entry written before cutover, re-read after cutover — since there's no persistent storage, this entry only survives if `redis-leader` was never recreated.

Success criteria, checked by `task verify:report`:

- Zero failed HTTP requests across the whole run.
- No pod restart-count or creation-timestamp changes attributable to the cutover.
- The canary entry is still readable after migration.

## Repo layout

```
flux-to-argo/
├── Taskfile.yml
├── README.md                      # human walkthrough, one section per `task` target
├── chart/guestbook/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── frontend-{deployment,service}.yaml
│       ├── redis-leader-{deployment,service}.yaml
│       └── redis-follower-{deployment,service}.yaml
├── cluster/
│   ├── kind-config.yaml
│   ├── flux/
│   │   ├── guestbook-source.yaml   # GitRepository
│   │   └── guestbook-release.yaml  # HelmRelease
│   └── argocd/
│       └── guestbook-app.yaml      # ArgoCD Application, applied at cutover
├── scripts/
│   ├── cluster-up.sh
│   ├── akp-up.sh
│   ├── deploy-flux.sh
│   ├── verify-start.sh
│   ├── verify-report.sh
│   ├── migrate.sh
│   ├── cleanup-flux.sh
│   └── teardown.sh
└── docs/superpowers/specs/2026-08-10-flux-to-argo-poc-design.md
```

## Error handling

- **Diff shows unexpected drift at step 6b**: abort before suspending Flux; fix the AKP `Application` source/values until the diff is clean, then retry.
- **AKP sync fails at step 6d**: Flux is still suspended but the old resources are untouched (no delete+recreate happened), so the fix is either resolving the sync error or resuming Flux and deleting the `Application` to fully roll back.
- **Probe records a failure or a restart-count change during cutover**: this is the PoC surfacing a real problem, not something to handle silently — `verify:report` should print exactly when and what changed so it's visible in the walkthrough.

## Out of scope for correctness (accepted assumptions)

- The guestbook images (`redis`, and a small frontend) are assumed to be publicly pullable — no private registry auth is set up for this PoC.
- `akuity` CLI is assumed to already be authenticated against an org with permission to create a new instance; auth setup itself is not scripted here.
