# Helm-First to GitOps-Ready: Lookup & Hooks Pitfalls Demo

**Date:** 2026-08-11
**Status:** Approved

## Purpose

Add a second, standalone scenario to this repo showing a "helm-first" developer — one who leans on native Helm features that assume Helm itself manages the release lifecycle — hitting two specific, real pitfalls when the same chart is deployed via ArgoCD instead of `helm install`/`helm upgrade`, and how to refactor a chart to work correctly under both. This directly answers a request to show developers moving off Flux+native-Helm patterns onto ArgoCD how to handle `lookup` and Helm hooks, the two most common blockers in practice.

Both pitfalls are grounded in real fixes shipped in `adamancini/akkoma-helm` and `adamancini/soju-helm` (see citations below), not hypothetical examples.

## Non-goals

- Not a general Helm-hooks/lookup reference — doesn't enumerate every hook type or every `lookup` use case, only the two that broke in practice.
- Not testing scale, HA, or multi-cluster fleets.
- Does not touch, modify, or re-verify the existing guestbook zero-downtime migration scenario. This is a second, independent scenario that happens to share infrastructure.
- Not fixing the vendored third-party chart's underlying non-idempotency — only its ArgoCD lifecycle mapping (see Pitfall 2).

## The two pitfalls (with evidence)

### Pitfall 1: `lookup`-based secret generation breaks under `helm template`

A chart generates a random secret (session key, admin password) and uses `lookup "v1" "Secret" ...` to check for an existing value on upgrade, preserving it across `helm upgrade` runs. `lookup` only reads live cluster state during `helm install`/`helm upgrade` — under `helm template`, which is what ArgoCD renders with (ArgoCD never calls Helm's install/upgrade path), it always returns empty. The chart silently regenerates a new random secret on *every* sync.

Real-world evidence: `akkoma-helm@8f201f8` ("Add GitOps-safe secret resolution") and `soju-helm@9156639` ("Make admin secret resolution value-first for GitOps") both fixed exactly this, after the lookup-only pattern was introduced in `akkoma-helm@84f0a9f` and `soju-helm@9ae06ef`. Fallout noted in `akkoma-helm`'s CHANGELOG: "Random secrets are no longer regenerated on every render under GitOps tooling" — regeneration was invalidating user sessions on every sync.

**Fix:** resolve each secret with precedence **explicit value > existing in-cluster value (via `lookup`, for native-Helm users) > random fallback**, plus an `existingSecret` escape hatch referencing an out-of-band-managed Secret. Native Helm users lose nothing (their upgrade-time `lookup` still fires when no explicit value is set); ArgoCD/GitOps users set the value explicitly (managed via SOPS/Sealed Secrets) and get a stable render.

### Pitfall 2: Helm hooks aren't release-tracked, and their lifecycle doesn't map 1:1 to ArgoCD sync

Helm's own docs are explicit that hook resources are not managed with the corresponding release — `helm uninstall`/`rollback` don't touch them (https://helm.sh/docs/topics/charts_hooks/#hook-resources-are-not-managed-with-corresponding-releases). That untracked-ness is what lets the ArgoCD mismatch cause real damage. Per an analysis of the conflict (https://oneuptime.com/blog/post/2026-02-26-how-to-handle-helm-chart-hooks-vs-argocd-hooks-conflict/view#where-the-conflict-happens):

- ArgoCD renders with `helm template`, never `helm install`/`upgrade`, so it has no install-vs-upgrade distinction — `post-install` and `post-upgrade` both collapse to ArgoCD's `PostSync`, meaning a hook meant to run once now fires on **every sync**.
- Unsupported hook types (`test`, rollback hooks) have no ArgoCD equivalent and are silently skipped — confirmed by `gitops-engine`'s hook-filtering behavior (https://github.com/argoproj/gitops-engine/blob/6b2984ebc47085852a7b63a0fd0b73c52e986217/pkg/sync/ignore/ignore.go#L11), discussed in argoproj/argo-cd#15302.
- If a resource carries both `helm.sh/hook` and `argocd.argoproj.io/hook` annotations, ArgoCD's own annotation silently wins.
- Even ArgoCD's own default mapping is debated as wrong in places — argoproj/argo-cd#17604 argues `post-install,post-upgrade` should map to ArgoCD's `Sync` phase, not `PostSync`, because Helm runs those hooks once all resources are *applied*, not once they're *healthy*.

Real-world evidence: `soju-helm@3066047` added a non-idempotent `post-install` Job (admin-user creation via `sojudb create-user`, no existing-user check). `soju-helm@d158e22` ("fix: make admin-setup Job idempotent for Argo CD re-syncs") fixed the resulting production failure — the Job re-ran on every ArgoCD sync, `hook-delete-policy: hook-succeeded` deleted the completed Job each time so ArgoCD saw nothing to skip, and the unguarded insert then hit a real `UNIQUE constraint failed` error that left a stuck failed Job blocking the next sync.

**Better fix, for charts we own:** don't map the Job to an ArgoCD hook at all. Convert it to a **plain, statically-named, tracked resource** (part of the chart's normal templated output, no `helm.sh/hook*` annotations; add `argocd.argoproj.io/sync-wave` only if ordering relative to other resources actually matters). This fixes the root cause, not just the symptom: a Job with a static name and an unchanged rendered spec produces *no diff* on subsequent syncs, so ArgoCD never re-applies or re-creates it — it only touches the Job again if something about it actually changes (image bump, manual deletion). Idempotent Job logic (`INSERT OR IGNORE`, existence check) stays as defense-in-depth, but it's no longer the only thing standing between correctness and a failed sync.

**For third-party charts we can't edit or fork:** we can't remove their `helm.sh/hook` annotations or fix non-idempotent logic inside them. The mitigation (per the oneuptime post) is a Kustomize overlay or Helm post-renderer that rewrites `helm.sh/hook`/`hook-weight`/`hook-delete-policy` into explicit `argocd.argoproj.io/hook`/`sync-wave`/`hook-delete-policy` equivalents at render time. This gives us control over ArgoCD's *lifecycle mapping* (e.g. forcing `post-install` to `Sync` per the argo-cd#17604 argument above) even though the Job's own non-idempotency remains out of our hands.

## Architecture

Reuses the existing k3d cluster (`flux-to-argo`) and AKP instance (`flux-to-argo-poc`) provisioned by the guestbook scenario — no new billable infrastructure. A new namespace, `adminapp-demo`, keeps everything isolated from `guestbook-demo`.

Three chart artifacts under `chart/`:

1. **`chart/adminapp-helmfirst/`** — the anti-pattern, owned by us. A minimal Deployment (env-injected secret, so churn is visible via pod restart/age), a `lookup`-based Secret (Pitfall 1), and a non-idempotent `post-install` hook Job (Pitfall 2) that creates an admin row in a SQLite file on a PVC, so a second run genuinely hits a `UNIQUE constraint` error rather than a simulated one.
2. **`chart/adminapp-gitops/`** — the fix, owned by us. Same app: secret resolution follows the explicit/lookup/random precedence chain; the hook Job becomes a plain, statically-named, tracked Job with idempotent SQL as defense-in-depth.
3. **`chart/vendored-widget-kustomize/vendored-widget/`** — a stand-in for a third-party chart we're not allowed to edit, clearly marked `DO NOT EDIT` in every file's header. Same shape of problem (lookup + hook Job), deliberately left broken. Paired with a Kustomize overlay at `chart/vendored-widget-kustomize/kustomization.yaml`, using Kustomize's `helmCharts` chart-inflator generator plus a `patches:` block rewriting the Job's `helm.sh/hook*` annotations to `argocd.argoproj.io/hook*` equivalents at render time. Requires `kustomize.buildOptions: --enable-helm` added to the AKP instance's `argocd_cm` (one line in the existing `terraform/01-argocd/main.tf`).

The vendored chart is nested directly inside the overlay's own directory (`chart/vendored-widget-kustomize/vendored-widget/`), not referenced from a separate `chart/vendored-widget/` tree — verified empirically that Kustomize's default load restriction (`LoadRestrictionsRootOnly`) refuses to load any file outside the directory rooted at the top-level `kustomization.yaml`, so `helmGlobals.chartHome` must resolve to a genuine subdirectory of the overlay, not a path reaching elsewhere in the repo. This is also a more realistic simulation of vendoring: real third-party charts usually get copied into your own tree (e.g. `helm pull --untar`), not left in a distant, unrelated directory. The alternative — relaxing the restriction with `--load-restrictor LoadRestrictionsNone` in `kustomize.buildOptions` — was considered and rejected: that flag disables a real security control instance-wide (every Kustomize build the AKP instance's repo-server runs, not just this one Application), which isn't worth it when nesting the chart avoids the problem entirely.

## Demo flow

Mirrors the guestbook scenario's "Flux first, then ArgoCD reveals the problem" shape, but without the zero-downtime verification-probe machinery — these are deterministic template-rendering/lifecycle bugs, not timing races, so proof is a direct before/after comparison printed to the terminal, not a background probe.

1. **`task adminapp:deploy-flux`** — deploy `chart/adminapp-helmfirst` via a Flux `HelmRelease` into `adminapp-demo`. Works fine: Flux's helm-controller performs real Helm SDK installs/upgrades, so `lookup` genuinely works and the hook Job only runs once (real install-vs-upgrade distinction). This is the "looks fine, ships to prod, no one notices anything wrong yet" beat.
2. **`task adminapp:break`** — create an ArgoCD `Application` pointed at the same `chart/adminapp-helmfirst` path, sync it twice, and print direct evidence of both failures:
   - the rendered `session-secret` value differs between the two syncs (proving Pitfall 1 — under Flux this never happened)
   - the second sync's hook Job fails with a `UNIQUE constraint failed` error and the Application's health goes `Degraded` (proving Pitfall 2)
3. **`task adminapp:fix`** — repoint the same Application's source path to `chart/adminapp-gitops`, sync twice more, and print evidence the secret is now stable across syncs and the Job succeeds/no-ops both times, health `Healthy`.
4. **`task adminapp:vendored`** — deploy `chart/vendored-widget-kustomize/vendored-widget` via the Kustomize overlay, and diff the vendored chart's raw `helm template` output against the ArgoCD Application's actual applied manifests (`argocd app manifests`) to show the hook annotations were rewritten at render time without editing the chart.
5. **`task adminapp:cleanup`** — delete the Flux `HelmRelease`/`GitRepository` and all three ArgoCD `Application`s created above. Folded into the existing `task down` teardown so nothing new needs a separate lifecycle.

## Repo layout additions

```
flux-to-argo/
├── chart/
│   ├── adminapp-helmfirst/         # anti-pattern: lookup secret + post-install hook Job
│   ├── adminapp-gitops/            # fix: precedence-chain secret + plain idempotent Job
│   └── vendored-widget/            # DO NOT EDIT — simulated third-party chart
├── cluster/
│   ├── flux/
│   │   └── adminapp-source.yaml, adminapp-release.yaml
│   └── argocd/
│       ├── adminapp-app.yaml               # repointed between helmfirst/gitops in Task adminapp:fix
│       ├── vendored-widget-app.yaml
│       └── vendored-widget-kustomize/
│           └── kustomization.yaml
├── scripts/
│   ├── adminapp-deploy-flux.sh
│   ├── adminapp-break.sh
│   ├── adminapp-fix.sh
│   ├── adminapp-vendored.sh
│   └── adminapp-cleanup.sh
└── docs/superpowers/specs/2026-08-11-helm-lookup-hooks-demo-design.md
```

## Error handling

- **SQLite CLI image unpullable or missing expected flags**: verified locally (`docker run --rm <image> sqlite3 -version`) during implementation before it's wired into any Job spec.
- **Kustomize `helmCharts` local-chart resolution fails against the AKP repo-server's bundled Kustomize/Helm versions** (verified locally against Kustomize v5.5.0 + Helm 3.16.4, but the AKP-hosted repo-server's exact versions are unconfirmed until Task 8 actually deploys through it): fall back to a checked-in, pre-patched manifest directory instead of the live Kustomize overlay.
- **`kustomize.buildOptions` isn't honored on the hosted AKP instance** (Akuity may restrict some `argocd_cm` keys on managed control planes): same fallback as above.
- **`adminapp:break`'s second sync doesn't actually re-trigger the hook Job**: would contradict the documented root cause of the real `soju-helm` bug (ArgoCD always re-creates hook resources at the appropriate sync phase since `hook-succeeded` deletes the prior instance) — low risk, but if it doesn't reproduce, the task should fail loudly with the actual observed Job/Application state rather than asserting success.

## Out of scope for correctness (accepted assumptions)

- `chart/vendored-widget-kustomize/vendored-widget`'s non-idempotent Job logic is intentionally never fixed — only its ArgoCD lifecycle mapping is. That gap is the point of the third chart.
- The PVC backing each chart's SQLite file assumes k3d's default `local-path` storage class is available, which it is in any stock k3d cluster.
- No new zero-downtime or performance verification is added — this scenario is about GitOps chart-authoring correctness, not availability, and doesn't reuse or extend the guestbook scenario's probe.
