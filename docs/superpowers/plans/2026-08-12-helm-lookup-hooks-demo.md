# Helm-First to GitOps-Ready: Lookup & Hooks Pitfalls Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, standalone demo scenario to this repo showing a "helm-first" chart hitting two real pitfalls under ArgoCD (a `lookup`-based secret that silently regenerates under `helm template`, and a non-idempotent `post-install` hook Job that ArgoCD re-triggers on every sync), then refactoring the chart to fix both — plus a third mini-demo showing how to mitigate the hooks pitfall for a third-party chart you can't edit, via a Kustomize overlay that rewrites its Helm hook annotations to ArgoCD-native equivalents.

**Architecture:** Three new Helm charts (`chart/adminapp-helmfirst`, `chart/adminapp-gitops`, `chart/vendored-widget`) deployed into a new `adminapp-demo` namespace on the same k3d cluster and AKP instance the guestbook scenario already provisions. The anti-pattern chart is deployed via Flux first (where it works fine), then adopted by an ArgoCD `Application` (where both pitfalls surface), then the Application is repointed at the fixed chart. The vendored chart is deployed straight to ArgoCD via a Kustomize overlay that patches its hook annotations at render time, without editing the chart.

**Tech Stack:** k3d, Flux, Helm 3.x, ArgoCD (`argocd` CLI), Kustomize v5+ (`--enable-helm`), Terraform (`akuity/akp` provider), SQLite (`keinos/sqlite3:3.46.0` image), go-task, bash, `jq`.

## Global Constraints

- Spec of record: `docs/superpowers/specs/2026-08-11-helm-lookup-hooks-demo-design.md` — every task below implements one part of it; consult it for the "why" behind any step.
- **Depends on the guestbook scenario's infra already being up**: `task cluster:up` and `task akp:up` must have already been run (they provision the k3d cluster `flux-to-argo` and the AKP instance `flux-to-argo-poc`/registered cluster `flux-to-argo` this plan reuses). This plan does not provision or tear down that infra itself.
- New namespace `adminapp-demo` isolates everything in this plan from the guestbook scenario's `guestbook-demo` namespace. Nothing in this plan modifies `chart/guestbook`, `cluster/flux/guestbook-*`, or `cluster/argocd/guestbook-app.yaml`.
- Required tools, in addition to the guestbook scenario's list (`k3d`, `kubectl`, `helm`, `flux`, `terraform`, `argocd`, `gh`, `jq`, `curl`, `task`): a standalone **Kustomize v5+ binary** (not `kubectl kustomize`, which doesn't support `--enable-helm`) for locally verifying the Task 7 overlay before wiring it into a live Application.
- **Helm version matters for the Kustomize overlay**: Kustomize's `--enable-helm` chart inflator shells out to `helm version -c --short`. This works against Helm 3.x (verified against 3.16.4) but fails against Helm 4.x, which removed the legacy `-c` flag entirely ("unknown shorthand flag: 'c' in -c"). ArgoCD 2.13.2 (this repo's AKP instance version) bundles Helm 3.x, so the live Application in Task 8 is expected to work; if your local `helm` on `PATH` resolves to v4+, use a separate Helm 3.x binary on `PATH` for Task 7's local `kustomize build` verification step specifically.
- The `keinos/sqlite3:3.46.0` image is verified pullable and behaves exactly as this plan assumes: a bare `INSERT` against a `UNIQUE` column that already has the value exits **19** with `Error: stepping, UNIQUE constraint failed: users.username (19)`; `INSERT OR IGNORE` with the same duplicate exits **0**.
- **Real-world actions requiring explicit confirmation at execution time** (mutate the already-live k3d cluster / AKP instance from the guestbook scenario; not to be run unattended without checking with the user first): every `argocd app create/set/sync/delete` and `flux suspend` call in Tasks 5, 6, 8, 9, and the `terraform apply` in Task 7 Step 4 (edits the live AKP instance's `argocd_cm`). `helm lint`/`helm template`/local `kustomize build`/`terraform validate` are safe to run freely.

---

### Task 1: Taskfile wiring for the new scenario's targets

**Files:**
- Modify: `Taskfile.yml`

**Interfaces:**
- Consumes: nothing new.
- Produces: 5 `task` targets (`adminapp:deploy-flux`, `adminapp:break`, `adminapp:fix`, `adminapp:vendored`, `adminapp:cleanup`), each shelling out to a same-named script under `scripts/` that later tasks create. Running any target before its script exists is expected to fail with "no such file" until that task lands.

- [ ] **Step 1: Add the five new tasks to `Taskfile.yml`**

Open `Taskfile.yml` and add the following inside the existing `tasks:` block (anywhere after the existing tasks is fine — go-task doesn't care about order):

```yaml
  adminapp:deploy-flux:
    desc: Deploy the adminapp-helmfirst chart via a Flux HelmRelease
    cmds:
      - ./scripts/adminapp-deploy-flux.sh

  adminapp:break:
    desc: Adopt adminapp under ArgoCD and reproduce the lookup/hooks pitfalls
    cmds:
      - ./scripts/adminapp-break.sh

  adminapp:fix:
    desc: Repoint the ArgoCD Application at the refactored chart and prove both pitfalls are fixed
    cmds:
      - ./scripts/adminapp-fix.sh

  adminapp:vendored:
    desc: Deploy the vendored-widget chart via a Kustomize overlay and show the hook annotation rewrite
    cmds:
      - ./scripts/adminapp-vendored.sh

  adminapp:cleanup:
    desc: Remove all adminapp/vendored-widget Flux and ArgoCD objects
    cmds:
      - ./scripts/adminapp-cleanup.sh
```

- [ ] **Step 2: Verify the Taskfile is still valid**

Run: `task --list`
Expected: the 5 new tasks above appear (with their `desc` text) alongside the existing guestbook-scenario tasks, with no YAML parse errors.

- [ ] **Step 3: Commit**

```bash
git add Taskfile.yml
git commit -m "Wire Taskfile targets for the lookup/hooks pitfalls demo"
```

---

### Task 2: Author the anti-pattern chart (`chart/adminapp-helmfirst`)

**Files:**
- Create: `chart/adminapp-helmfirst/Chart.yaml`
- Create: `chart/adminapp-helmfirst/values.yaml`
- Create: `chart/adminapp-helmfirst/templates/deployment.yaml`
- Create: `chart/adminapp-helmfirst/templates/secret.yaml`
- Create: `chart/adminapp-helmfirst/templates/pvc.yaml`
- Create: `chart/adminapp-helmfirst/templates/job-admin-user.yaml`

**Interfaces:**
- Consumes: nothing (first content task).
- Produces: a chart named `adminapp` (version `0.1.0`) rendering a Deployment (`adminapp`), a `lookup`-based Secret (`adminapp-session`, key `session-secret`), a PVC (`adminapp-db`), and a non-idempotent `helm.sh/hook: post-install` Job (`adminapp-admin-user`). Task 4 deploys this via Flux; Task 5's ArgoCD adoption depends on these exact resource names.

- [ ] **Step 1: Create `chart/adminapp-helmfirst/Chart.yaml`**

```yaml
apiVersion: v2
name: adminapp
description: Minimal demo app illustrating a helm-first lookup-based secret and a non-idempotent post-install hook Job
type: application
version: 0.1.0
appVersion: "1.0"
```

- [ ] **Step 2: Create `chart/adminapp-helmfirst/values.yaml`**

```yaml
image:
  repository: busybox
  tag: "1.36"

sqlite:
  image:
    repository: keinos/sqlite3
    tag: "3.46.0"
```

- [ ] **Step 3: Create `chart/adminapp-helmfirst/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminapp
  labels:
    app: adminapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminapp
  template:
    metadata:
      labels:
        app: adminapp
    spec:
      containers:
        - name: adminapp
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["sh", "-c", "echo adminapp running with SESSION_SECRET=$SESSION_SECRET; sleep infinity"]
          env:
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: adminapp-session
                  key: session-secret
```

- [ ] **Step 4: Create `chart/adminapp-helmfirst/templates/secret.yaml`**

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace "adminapp-session" }}
apiVersion: v1
kind: Secret
metadata:
  name: adminapp-session
  labels:
    app: adminapp
type: Opaque
data:
  {{- if $existing }}
  # Preserve the existing value on upgrade -- only works when Helm itself
  # manages the release (helm install/upgrade). Under `helm template`
  # (ArgoCD), the lookup above always returns nothing, so this branch is
  # never taken there -- see the design spec for why.
  session-secret: {{ index $existing.data "session-secret" }}
  {{- else }}
  # Generate a random value on first install.
  session-secret: {{ randAlphaNum 32 | b64enc | quote }}
  {{- end }}
```

- [ ] **Step 5: Create `chart/adminapp-helmfirst/templates/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: adminapp-db
  labels:
    app: adminapp
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 64Mi
```

- [ ] **Step 6: Create `chart/adminapp-helmfirst/templates/job-admin-user.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: adminapp-admin-user
  annotations:
    "helm.sh/hook": post-install
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  # No retries: one pod attempt, one exit code, so a failure is immediately
  # visible instead of being retried/masked by the Job controller.
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: create-admin
          image: "{{ .Values.sqlite.image.repository }}:{{ .Values.sqlite.image.tag }}"
          command:
            - sh
            - -c
            - |
              sqlite3 /data/admin.db "CREATE TABLE IF NOT EXISTS users (username TEXT UNIQUE);"
              sqlite3 /data/admin.db "INSERT INTO users(username) VALUES('admin');"
          volumeMounts:
            - name: db
              mountPath: /data
      volumes:
        - name: db
          persistentVolumeClaim:
            claimName: adminapp-db
```

- [ ] **Step 7: Verify the chart lints, renders the expected resources, and reproduces Pitfall 1 without a cluster**

Run:
```bash
helm lint chart/adminapp-helmfirst
helm template chart/adminapp-helmfirst | grep -c '^kind: Deployment'
helm template chart/adminapp-helmfirst | grep -c '^kind: Secret'
helm template chart/adminapp-helmfirst | grep -c '^kind: PersistentVolumeClaim'
helm template chart/adminapp-helmfirst | grep -c '^kind: Job'
helm template chart/adminapp-helmfirst | grep 'session-secret:'
helm template chart/adminapp-helmfirst | grep 'session-secret:'
```
Expected: `helm lint` reports `0 chart(s) failed`; the four `grep -c` commands each print `1`; the two final `grep` commands print a `session-secret:` line each, with **different** base64 values (no live cluster is needed for `lookup` to return empty — this is Pitfall 1, reproduced locally).

- [ ] **Step 8: Commit**

```bash
git add chart/adminapp-helmfirst
git commit -m "Add adminapp-helmfirst chart (lookup secret + non-idempotent hook Job)"
```

---

### Task 3: Author the fixed chart (`chart/adminapp-gitops`)

**Files:**
- Create: `chart/adminapp-gitops/Chart.yaml`
- Create: `chart/adminapp-gitops/values.yaml`
- Create: `chart/adminapp-gitops/templates/_helpers.tpl`
- Create: `chart/adminapp-gitops/templates/deployment.yaml`
- Create: `chart/adminapp-gitops/templates/secret.yaml`
- Create: `chart/adminapp-gitops/templates/pvc.yaml`
- Create: `chart/adminapp-gitops/templates/job-admin-user-setup.yaml`

**Interfaces:**
- Consumes: nothing (parallel chart to Task 2, not built on top of it).
- Produces: a chart named `adminapp` (version `0.2.0`) rendering the *same* Deployment (`adminapp`), Secret (`adminapp-session`), and PVC (`adminapp-db`) names as `adminapp-helmfirst` — required so Task 6 can repoint the same ArgoCD `Application` at this chart in place, without ArgoCD treating it as a delete-and-recreate. The Secret now resolves via `adminapp.resolveSecret` (explicit value > existing lookup > random). The hook Job is replaced by a plain, statically-named, idempotent Job `adminapp-admin-user-setup` (no `helm.sh/hook*` annotations).

- [ ] **Step 1: Create `chart/adminapp-gitops/Chart.yaml`**

```yaml
apiVersion: v2
name: adminapp
description: adminapp refactored to resolve secrets and admin-user setup safely under both native Helm and ArgoCD
type: application
version: 0.2.0
appVersion: "1.0"
```

- [ ] **Step 2: Create `chart/adminapp-gitops/values.yaml`**

```yaml
image:
  repository: busybox
  tag: "1.36"

sqlite:
  image:
    repository: keinos/sqlite3
    tag: "3.46.0"

# Session secret. Precedence: this value > existing in-cluster value > random.
# Set this explicitly for GitOps/ArgoCD (manage it with SOPS/Sealed Secrets in
# real usage) -- the in-cluster lookup this falls back to only works under
# `helm install`/`helm upgrade`, and the random fallback after that would be
# regenerated on every `helm template` render.
sessionSecret: ""
```

- [ ] **Step 3: Create `chart/adminapp-gitops/templates/_helpers.tpl`**

```
{{/*
Resolve a generated secret value, returning a base64-encoded string suitable
for a Secret `data:` field. Precedence: explicit value > existing in-cluster
value > random.

The in-cluster lookup only succeeds during `helm install`/`helm upgrade`;
under `helm template` (e.g. ArgoCD), it returns empty, so an explicit value is
the only way to keep a value stable across GitOps renders.

Args (dict):
  ctx        - root context (.)
  value      - explicit plaintext value ("" to fall back)
  secretName - name of the Secret to look up for preservation
  key        - data key within that Secret
  length     - length of the random fallback
*/}}
{{- define "adminapp.resolveSecret" -}}
{{- if .value -}}
{{- .value | b64enc -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secretName -}}
{{- if and $existing $existing.data (index $existing.data .key) -}}
{{- index $existing.data .key -}}
{{- else -}}
{{- randAlphaNum (.length | int) | b64enc -}}
{{- end -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 4: Create `chart/adminapp-gitops/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminapp
  labels:
    app: adminapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminapp
  template:
    metadata:
      labels:
        app: adminapp
    spec:
      containers:
        - name: adminapp
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["sh", "-c", "echo adminapp running with SESSION_SECRET=$SESSION_SECRET; sleep infinity"]
          env:
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: adminapp-session
                  key: session-secret
```

- [ ] **Step 5: Create `chart/adminapp-gitops/templates/secret.yaml`**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: adminapp-session
  labels:
    app: adminapp
type: Opaque
data:
  session-secret: {{ include "adminapp.resolveSecret" (dict "ctx" . "value" .Values.sessionSecret "secretName" "adminapp-session" "key" "session-secret" "length" 32) | quote }}
```

- [ ] **Step 6: Create `chart/adminapp-gitops/templates/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: adminapp-db
  labels:
    app: adminapp
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 64Mi
```

- [ ] **Step 7: Create `chart/adminapp-gitops/templates/job-admin-user-setup.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  # Static name, no helm.sh/hook* annotations: this is now a plain, tracked
  # resource. Its rendered spec doesn't change between syncs, so ArgoCD sees
  # no diff after the first successful run and never re-applies or
  # re-creates it -- it only touches this Job again if something about it
  # actually changes (image bump, manual deletion). The idempotent SQL below
  # is defense-in-depth for exactly those cases, not the only thing
  # preventing a re-run.
  name: adminapp-admin-user-setup
  labels:
    app: adminapp
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: create-admin
          image: "{{ .Values.sqlite.image.repository }}:{{ .Values.sqlite.image.tag }}"
          command:
            - sh
            - -c
            - |
              sqlite3 /data/admin.db "CREATE TABLE IF NOT EXISTS users (username TEXT UNIQUE);"
              sqlite3 /data/admin.db "INSERT OR IGNORE INTO users(username) VALUES('admin');"
          volumeMounts:
            - name: db
              mountPath: /data
      volumes:
        - name: db
          persistentVolumeClaim:
            claimName: adminapp-db
```

- [ ] **Step 8: Verify the chart lints, renders the expected resources, and the fix actually holds**

Run:
```bash
helm lint chart/adminapp-gitops
helm template chart/adminapp-gitops | grep -c '^kind: Deployment'
helm template chart/adminapp-gitops | grep -c '^kind: Secret'
helm template chart/adminapp-gitops | grep -c '^kind: PersistentVolumeClaim'
helm template chart/adminapp-gitops | grep -c '^kind: Job'
helm template chart/adminapp-gitops --set sessionSecret=demo-stable-session-secret | grep 'session-secret:'
helm template chart/adminapp-gitops --set sessionSecret=demo-stable-session-secret | grep 'session-secret:'
```
Expected: `helm lint` reports `0 chart(s) failed`; the four `grep -c` commands each print `1`; the two final `grep` commands print the **same** `session-secret:` base64 value both times (`ZGVtby1zdGFibGUtc2Vzc2lvbi1zZWNyZXQ=`) — proving the explicit-value precedence tier keeps the render stable, unlike Task 2's chart.

- [ ] **Step 9: Commit**

```bash
git add chart/adminapp-gitops
git commit -m "Add adminapp-gitops chart (precedence-chain secret + plain idempotent Job)"
```

---

### Task 4: Deploy `adminapp-helmfirst` via Flux

**Files:**
- Create: `cluster/flux/adminapp-source.yaml`
- Create: `cluster/flux/adminapp-release.yaml`
- Create: `scripts/adminapp-deploy-flux.sh`
- Modify: `README.md` (add the first "Bonus scenario" subsection)

**Interfaces:**
- Consumes: `chart/adminapp-helmfirst` from Task 2; the `k3d-flux-to-argo` context and running Flux controllers from the guestbook scenario (already up per Global Constraints).
- Produces: the adminapp workload running in namespace `adminapp-demo`, owned by a Flux `HelmRelease` named `adminapp` in `flux-system`. Task 5's ArgoCD adoption and `flux suspend` depend on this exact `HelmRelease` name/namespace.

- [ ] **Step 1: Create `cluster/flux/adminapp-source.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: adminapp
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/adamancini/flux-to-argo
  ref:
    branch: main
```

- [ ] **Step 2: Create `cluster/flux/adminapp-release.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: adminapp
  namespace: flux-system
spec:
  interval: 1m
  targetNamespace: adminapp-demo
  install:
    createNamespace: true
  chart:
    spec:
      chart: chart/adminapp-helmfirst
      sourceRef:
        kind: GitRepository
        name: adminapp
        namespace: flux-system
```

- [ ] **Step 3: Create `scripts/adminapp-deploy-flux.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f cluster/flux/adminapp-source.yaml
kubectl apply -f cluster/flux/adminapp-release.yaml

kubectl wait --for=condition=ready --timeout=180s \
  -n flux-system helmrelease/adminapp

kubectl wait --for=condition=available --timeout=180s \
  -n adminapp-demo deployment/adminapp
```

- [ ] **Step 4: Make the script executable**

```bash
chmod +x scripts/adminapp-deploy-flux.sh
```

- [ ] **Step 5: Run it and verify adminapp comes up under Flux, hook included, with no drift on a second reconcile**

Run (requires the guestbook scenario's cluster already up — see Global Constraints; commit first per the confirmation note above before running against the live cluster):
```bash
./scripts/adminapp-deploy-flux.sh
kubectl get helmrelease -n flux-system adminapp
kubectl get pods -n adminapp-demo
kubectl get job -n adminapp-demo
kubectl get secret adminapp-session -n adminapp-demo -o jsonpath='{.data.session-secret}'; echo
flux reconcile helmrelease adminapp -n flux-system
kubectl get secret adminapp-session -n adminapp-demo -o jsonpath='{.data.session-secret}'; echo
```
Expected: `HelmRelease` shows `READY=True`; the `adminapp` pod is `Running`/`1/1`; `kubectl get job` shows the `adminapp-admin-user` Job `Complete`; the `session-secret` value printed **before and after** the forced `flux reconcile` is **identical** — under Flux's real Helm SDK upgrade, `lookup` preserves it correctly (unlike what Task 5 will show under ArgoCD).

- [ ] **Step 6: Add the first "Bonus scenario" section to `README.md`**

Append this new top-level section at the end of `README.md`, after the existing "### 7. Tear down" section:

```markdown
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
```

- [ ] **Step 7: Commit**

```bash
git add cluster/flux/adminapp-source.yaml cluster/flux/adminapp-release.yaml scripts/adminapp-deploy-flux.sh README.md
git commit -m "Deploy adminapp-helmfirst via Flux"
```

---

### Task 5: Adopt `adminapp` under ArgoCD and reproduce both pitfalls

**Files:**
- Create: `cluster/argocd/adminapp-app.yaml`
- Create: `scripts/adminapp-break.sh`
- Modify: `README.md` (add the second "Bonus scenario" subsection)

**Interfaces:**
- Consumes: the Flux-managed `adminapp` from Task 4; the AKP instance and registered `flux-to-argo` cluster from the guestbook scenario.
- Produces: an ArgoCD `Application` named `adminapp` (namespace `argocd` on the AKP instance) adopting the same live resources Flux created, and a suspended Flux `HelmRelease` `adminapp`. Task 6 repoints this same `Application`'s source at `chart/adminapp-gitops`.

- [ ] **Step 1: Create `cluster/argocd/adminapp-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: adminapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/adamancini/flux-to-argo
    targetRevision: main
    path: chart/adminapp-helmfirst
  destination:
    name: flux-to-argo
    namespace: adminapp-demo
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
  # Adopting resources Flux already created -- ArgoCD stamps a tracking-id
  # annotation on first adoption of each resource kind, which would
  # otherwise look like drift on the very first diff/sync. See the guestbook
  # scenario's cluster/argocd/guestbook-app.yaml for the same pattern.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /metadata/annotations/argocd.argoproj.io~1tracking-id
    - group: ""
      kind: Secret
      jsonPointers:
        - /metadata/annotations/argocd.argoproj.io~1tracking-id
    - group: ""
      kind: PersistentVolumeClaim
      jsonPointers:
        - /metadata/annotations/argocd.argoproj.io~1tracking-id
```

- [ ] **Step 2: Create `scripts/adminapp-break.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="adminapp"
NAMESPACE="adminapp-demo"

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

secret_value() {
  kubectl get secret adminapp-session -n "${NAMESPACE}" -o jsonpath='{.data.session-secret}' 2>/dev/null || echo "MISSING"
}

job_state() {
  echo "--- job/adminapp-admin-user ---"
  kubectl get job adminapp-admin-user -n "${NAMESPACE}" 2>&1 || true
  echo "--- logs ---"
  kubectl logs job/adminapp-admin-user -n "${NAMESPACE}" 2>&1 || true
}

argocd_state() {
  local json
  if ! json="$(argocd app get "${APP_NAME}" -o json 2>/dev/null)"; then
    echo "--- argocd: application '${APP_NAME}' not found ---"
    return
  fi
  echo "--- argocd: application '${APP_NAME}': sync=$(echo "${json}" | jq -r '.status.sync.status') health=$(echo "${json}" | jq -r '.status.health.status') ---"
}

section "BEFORE: adminapp is Flux-managed only; session-secret was set by Flux's install"
BASELINE_SECRET="$(secret_value)"
echo "session-secret (Flux-set): ${BASELINE_SECRET}"

section "STEP 1: Create the ArgoCD Application, pointed at the same chart/adminapp-helmfirst path"
argocd app create -f cluster/argocd/adminapp-app.yaml --upsert
argocd_state

section "STEP 2: Suspend Flux so it stops reconciling the resources ArgoCD is about to adopt"
flux suspend helmrelease adminapp -n flux-system

section "STEP 3: First ArgoCD sync -- adopts the Flux-created resources"
argocd app sync "${APP_NAME}" || true
argocd_state
SYNC1_SECRET="$(secret_value)"
echo "session-secret (after ArgoCD sync #1): ${SYNC1_SECRET}"
if [[ "${SYNC1_SECRET}" != "${BASELINE_SECRET}" ]]; then
  echo "PITFALL 1 CONFIRMED: session-secret changed on the very first ArgoCD render (lookup returns empty under helm template)."
else
  echo "session-secret unchanged (unexpected -- re-check chart/adminapp-helmfirst/templates/secret.yaml)"
fi
echo "The sqlite db on the PVC already has the 'admin' row from Flux's original install, so"
echo "this first ArgoCD-triggered hook run is expected to fail immediately:"
job_state

section "STEP 4: Second ArgoCD sync -- the previous failed Job was never deleted (hook-delete-policy is hook-succeeded only)"
argocd app sync "${APP_NAME}" || true
argocd_state
SYNC2_SECRET="$(secret_value)"
echo "session-secret (after ArgoCD sync #2): ${SYNC2_SECRET}"
if [[ "${SYNC2_SECRET}" != "${SYNC1_SECRET}" ]]; then
  echo "PITFALL 1 CONFIRMED (continuous churn): session-secret changed AGAIN on sync #2, not just on adoption."
fi
job_state

section "AFTER: both pitfalls reproduced"
echo "Pitfall 1 (lookup): session-secret values across three points --"
echo "  Flux baseline : ${BASELINE_SECRET}"
echo "  ArgoCD sync #1: ${SYNC1_SECRET}"
echo "  ArgoCD sync #2: ${SYNC2_SECRET}"
echo
echo "Pitfall 2 (hooks): sync #1's Job above should show a 'UNIQUE constraint failed' error in"
echo "its logs (the row already existed from Flux's original install). Sync #2 should show the"
echo "Application unhealthy/OutOfSync because the previous FAILED Job (never cleaned up -- only"
echo "hook-succeeded triggers deletion) blocks ArgoCD from creating a fresh one for this sync's"
echo "hook phase. Run 'argocd app get adminapp' for the full operation error message."
```

- [ ] **Step 3: Make the script executable**

```bash
chmod +x scripts/adminapp-break.sh
```

- [ ] **Step 4: Run it and confirm both pitfalls reproduce (requires user confirmation — see Global Constraints)**

Confirm with the user before running; this mutates the live AKP instance and k3d cluster.

Run: `./scripts/adminapp-break.sh`

Expected: the script's own PASS/FAIL-style commentary reports `PITFALL 1 CONFIRMED` twice; `job_state`'s log output for sync #1 contains `UNIQUE constraint failed`; `argocd app get adminapp` shows `health=Degraded` or the sync operation reporting an error after sync #2.

- [ ] **Step 5: Add the second "Bonus scenario" subsection to `README.md`**

Append after the "### 1. Deploy the anti-pattern chart via Flux" subsection added in Task 4:

```markdown
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
```

- [ ] **Step 6: Commit**

```bash
git add cluster/argocd/adminapp-app.yaml scripts/adminapp-break.sh README.md
git commit -m "Adopt adminapp under ArgoCD and reproduce the lookup/hooks pitfalls"
```

---

### Task 6: Repoint at the fixed chart and prove both pitfalls are resolved

**Files:**
- Create: `scripts/adminapp-fix.sh`
- Modify: `README.md` (add the third "Bonus scenario" subsection)

**Interfaces:**
- Consumes: the broken `adminapp` Application from Task 5; `chart/adminapp-gitops` from Task 3.
- Produces: the same `adminapp` Application repointed at `chart/adminapp-gitops`, healthy, with a stable secret and a clean, prunable Job named `adminapp-admin-user-setup`. Task 9's cleanup deletes this Application.

- [ ] **Step 1: Create `scripts/adminapp-fix.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="adminapp"
NAMESPACE="adminapp-demo"

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

secret_value() {
  kubectl get secret adminapp-session -n "${NAMESPACE}" -o jsonpath='{.data.session-secret}' 2>/dev/null || echo "MISSING"
}

job_state() {
  echo "--- job/adminapp-admin-user-setup ---"
  kubectl get job adminapp-admin-user-setup -n "${NAMESPACE}" 2>&1 || true
  echo "--- logs ---"
  kubectl logs job/adminapp-admin-user-setup -n "${NAMESPACE}" 2>&1 || true
}

argocd_state() {
  local json
  json="$(argocd app get "${APP_NAME}" -o json)"
  echo "--- argocd: application '${APP_NAME}': sync=$(echo "${json}" | jq -r '.status.sync.status') health=$(echo "${json}" | jq -r '.status.health.status') ---"
}

section "BEFORE: adminapp is still on chart/adminapp-helmfirst, in the broken state from 'task adminapp:break'"
argocd_state

section "STEP 1: Repoint the Application at the refactored chart, with an explicit session secret"
argocd app set "${APP_NAME}" \
  --repo https://github.com/adamancini/flux-to-argo \
  --path chart/adminapp-gitops \
  --revision main \
  --helm-set sessionSecret=demo-stable-session-secret

section "STEP 2: First sync on the refactored chart (prune removes the old stuck hook Job)"
argocd app sync "${APP_NAME}" --prune
argocd app wait "${APP_NAME}" --health --timeout 120
argocd_state
FIX_SYNC1_SECRET="$(secret_value)"
echo "session-secret (after fix sync #1): ${FIX_SYNC1_SECRET}"
job_state

section "STEP 3: Second sync -- proves the secret is stable and the Job stays a clean no-op"
argocd app sync "${APP_NAME}" --prune
argocd app wait "${APP_NAME}" --health --timeout 120
argocd_state
FIX_SYNC2_SECRET="$(secret_value)"
echo "session-secret (after fix sync #2): ${FIX_SYNC2_SECRET}"
job_state

section "AFTER: both pitfalls fixed"
if [[ "${FIX_SYNC1_SECRET}" == "${FIX_SYNC2_SECRET}" ]]; then
  echo "PITFALL 1 FIXED: session-secret is stable across syncs (${FIX_SYNC1_SECRET})."
else
  echo "session-secret still changing -- check that --helm-set sessionSecret=... took effect."
fi
echo "Pitfall 2: job/adminapp-admin-user-setup above should show Complete/exit 0 on both syncs"
echo "(idempotent INSERT OR IGNORE), and the old job/adminapp-admin-user from the helmfirst"
echo "chart should be gone (pruned):"
kubectl get job adminapp-admin-user -n "${NAMESPACE}" 2>&1 || echo "job/adminapp-admin-user correctly pruned (not found)"
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/adminapp-fix.sh
```

- [ ] **Step 3: Run it and confirm both pitfalls are resolved (requires user confirmation — see Global Constraints)**

Confirm with the user before running.

Run: `./scripts/adminapp-fix.sh`

Expected: `PITFALL 1 FIXED` is printed with the same secret value shown for both syncs; both `job_state` blocks show the Job `Complete` with exit `0`; the final `kubectl get job adminapp-admin-user` reports "not found" (pruned).

- [ ] **Step 4: Add the third "Bonus scenario" subsection to `README.md`**

Append after the "### 2. Adopt it under ArgoCD..." subsection added in Task 5:

```markdown
### 3. Refactor and repoint at the fixed chart

    task adminapp:fix

Repoints the same `Application` at `chart/adminapp-gitops` — the secret now
resolves with precedence **explicit value > existing in-cluster value >
random** (set here via `--helm-set sessionSecret=...`, in real usage managed
with SOPS/Sealed Secrets), and the hook Job is now a plain, statically-named,
idempotent resource instead of a Helm hook. Two syncs in a row show the
secret staying put and the Job completing cleanly both times — the old
broken hook Job gets pruned since it's no longer part of the chart's output.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/adminapp-fix.sh README.md
git commit -m "Repoint adminapp at the gitops chart and prove both pitfalls are fixed"
```

---

### Task 7: Author the vendored chart and its Kustomize annotation-rewrite overlay

**Files:**
- Create: `chart/vendored-widget/Chart.yaml`
- Create: `chart/vendored-widget/values.yaml`
- Create: `chart/vendored-widget/templates/deployment.yaml`
- Create: `chart/vendored-widget/templates/secret.yaml`
- Create: `chart/vendored-widget/templates/pvc.yaml`
- Create: `chart/vendored-widget/templates/job-admin-user.yaml`
- Create: `cluster/argocd/vendored-widget-kustomize/kustomization.yaml`
- Modify: `terraform/01-argocd/main.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks (a standalone simulated third-party chart).
- Produces: `chart/vendored-widget` (name `vendored-widget`, version `0.1.0`), deliberately left with the same anti-patterns as Task 2's chart and never fixed. A Kustomize overlay at `cluster/argocd/vendored-widget-kustomize/` that inflates this chart locally (via `helmGlobals.chartHome`) and rewrites its Job's `helm.sh/hook*` annotations to `argocd.argoproj.io/hook*` equivalents. Task 8's Application sources this overlay directly.

- [ ] **Step 1: Create `chart/vendored-widget/Chart.yaml`**

```yaml
# DO NOT EDIT -- this chart simulates a third-party chart pulled from an
# external Helm repository that we don't control and can't fork. Its
# lookup-based secret and non-idempotent post-install hook Job are left
# deliberately broken; see cluster/argocd/vendored-widget-kustomize/ for how
# to work around it without touching this chart's source, and
# docs/superpowers/specs/2026-08-11-helm-lookup-hooks-demo-design.md for why.
apiVersion: v2
name: vendored-widget
description: Simulated third-party chart with the same lookup/hooks anti-patterns as adminapp-helmfirst
type: application
version: 0.1.0
appVersion: "1.0"
```

- [ ] **Step 2: Create `chart/vendored-widget/values.yaml`**

```yaml
# DO NOT EDIT -- see Chart.yaml.
image:
  repository: busybox
  tag: "1.36"

sqlite:
  image:
    repository: keinos/sqlite3
    tag: "3.46.0"
```

- [ ] **Step 3: Create `chart/vendored-widget/templates/deployment.yaml`**

```yaml
{{/* DO NOT EDIT -- see Chart.yaml. */}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vendored-widget
  labels:
    app: vendored-widget
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vendored-widget
  template:
    metadata:
      labels:
        app: vendored-widget
    spec:
      containers:
        - name: vendored-widget
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["sh", "-c", "echo vendored-widget running with SESSION_SECRET=$SESSION_SECRET; sleep infinity"]
          env:
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: vendored-widget-session
                  key: session-secret
```

- [ ] **Step 4: Create `chart/vendored-widget/templates/secret.yaml`**

```yaml
{{/* DO NOT EDIT -- see Chart.yaml. */}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace "vendored-widget-session" }}
apiVersion: v1
kind: Secret
metadata:
  name: vendored-widget-session
  labels:
    app: vendored-widget
type: Opaque
data:
  {{- if $existing }}
  session-secret: {{ index $existing.data "session-secret" }}
  {{- else }}
  session-secret: {{ randAlphaNum 32 | b64enc | quote }}
  {{- end }}
```

- [ ] **Step 5: Create `chart/vendored-widget/templates/pvc.yaml`**

```yaml
{{/* DO NOT EDIT -- see Chart.yaml. */}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vendored-widget-db
  labels:
    app: vendored-widget
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 64Mi
```

- [ ] **Step 6: Create `chart/vendored-widget/templates/job-admin-user.yaml`**

```yaml
{{/* DO NOT EDIT -- see Chart.yaml. */}}
apiVersion: batch/v1
kind: Job
metadata:
  name: vendored-widget-admin-user
  annotations:
    "helm.sh/hook": post-install
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: create-admin
          image: "{{ .Values.sqlite.image.repository }}:{{ .Values.sqlite.image.tag }}"
          command:
            - sh
            - -c
            - |
              sqlite3 /data/admin.db "CREATE TABLE IF NOT EXISTS users (username TEXT UNIQUE);"
              sqlite3 /data/admin.db "INSERT INTO users(username) VALUES('admin');"
          volumeMounts:
            - name: db
              mountPath: /data
      volumes:
        - name: db
          persistentVolumeClaim:
            claimName: vendored-widget-db
```

- [ ] **Step 7: Create `cluster/argocd/vendored-widget-kustomize/kustomization.yaml`**

```yaml
# DO NOT EDIT the chart this inflates (chart/vendored-widget) -- this overlay
# exists specifically so we never have to. See
# docs/superpowers/specs/2026-08-11-helm-lookup-hooks-demo-design.md for why.
helmCharts:
  - name: vendored-widget
    version: 0.1.0
    releaseName: vendored-widget
helmGlobals:
  chartHome: ../../../chart
patches:
  - target:
      kind: Job
      name: vendored-widget-admin-user
    patch: |-
      - op: remove
        path: /metadata/annotations/helm.sh~1hook
      - op: remove
        path: /metadata/annotations/helm.sh~1hook-weight
      - op: remove
        path: /metadata/annotations/helm.sh~1hook-delete-policy
      - op: add
        path: /metadata/annotations/argocd.argoproj.io~1hook
        value: PostSync
      - op: add
        path: /metadata/annotations/argocd.argoproj.io~1hook-delete-policy
        value: HookSucceeded
```

- [ ] **Step 8: Verify the overlay renders correctly with a local Kustomize v5+ and Helm 3.x (see Global Constraints)**

Run (ensure a Helm 3.x binary, not Helm 4.x, resolves first on `PATH` for this command specifically — see Global Constraints):
```bash
helm lint chart/vendored-widget
kustomize build --enable-helm cluster/argocd/vendored-widget-kustomize
```
Expected: `helm lint` reports `0 chart(s) failed`; the `kustomize build` output contains a `Job` named `vendored-widget-admin-user` whose `annotations` block has `argocd.argoproj.io/hook: PostSync` and `argocd.argoproj.io/hook-delete-policy: HookSucceeded`, and contains **no** `helm.sh/hook*` keys at all.

- [ ] **Step 9: Add `kustomize.buildOptions` to the AKP instance's `argocd_cm` in `terraform/01-argocd/main.tf`**

Open `terraform/01-argocd/main.tf` and add a `"kustomize.buildOptions"` entry to the existing `argocd_cm` map on the `akp_instance.argocd` resource, alongside the existing `"accounts.admin"` entry:

```hcl
  argocd_cm = {
    "accounts.admin"         = "apiKey,login"
    "kustomize.buildOptions" = "--enable-helm"
  }
```

This tells the AKP instance's repo-server to pass `--enable-helm` to every Kustomize build it runs, which is what lets `helmCharts:` generators (like the one just added) work at all — without it, ArgoCD's repo-server rejects any `kustomization.yaml` containing a `helmCharts:` block.

- [ ] **Step 10: Validate the Terraform change**

Run:
```bash
terraform -chdir=terraform/01-argocd init -backend=false
terraform -chdir=terraform/01-argocd validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 11: Apply the change to the live AKP instance (requires user confirmation — see Global Constraints)**

Confirm with the user before running; this modifies the live AKP instance's `argocd_cm`.

Run: `terraform -chdir=terraform/01-argocd apply -auto-approve`

Expected: `Apply complete!` with `argocd_cm` shown as updated in the diff.

- [ ] **Step 12: Commit**

```bash
git add chart/vendored-widget cluster/argocd/vendored-widget-kustomize terraform/01-argocd/main.tf
git commit -m "Add vendored-widget chart and a Kustomize overlay to rewrite its hook annotations"
```

---

### Task 8: Deploy the vendored chart via the overlay and prove the rewrite took effect

**Files:**
- Create: `cluster/argocd/vendored-widget-app.yaml`
- Create: `scripts/adminapp-vendored.sh`
- Modify: `README.md` (add the fourth "Bonus scenario" subsection)

**Interfaces:**
- Consumes: `chart/vendored-widget` and the Kustomize overlay from Task 7; the `kustomize.buildOptions` change applied to the live AKP instance in Task 7.
- Produces: an ArgoCD `Application` named `vendored-widget`, sourced from the Kustomize overlay directory instead of the chart directly. Task 9's cleanup deletes this Application.

- [ ] **Step 1: Create `cluster/argocd/vendored-widget-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vendored-widget
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/adamancini/flux-to-argo
    targetRevision: main
    path: cluster/argocd/vendored-widget-kustomize
  destination:
    name: flux-to-argo
    namespace: adminapp-demo
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Create `scripts/adminapp-vendored.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

section "STEP 1: Render the vendored chart's raw hook annotations (untouched)"
helm template chart/vendored-widget | grep -B4 'kind: Job' | grep -E 'helm\.sh/hook|name: vendored-widget-admin-user' || true

section "STEP 2: Create and sync the ArgoCD Application (sourced via the Kustomize overlay)"
argocd app create -f cluster/argocd/vendored-widget-app.yaml --upsert
argocd app sync vendored-widget
argocd app wait vendored-widget --health --timeout 120

section "STEP 3: Compare what ArgoCD actually applied against the raw chart"
echo "Actual applied manifest's Job annotations (via the Kustomize overlay):"
argocd app manifests vendored-widget | grep -B4 'kind: Job' | grep -E 'argocd\.argoproj\.io/hook|helm\.sh/hook|name: vendored-widget-admin-user' || true

section "AFTER: annotation rewrite confirmed"
echo "The raw chart (Step 1) still carries helm.sh/hook* annotations -- it was never edited."
echo "The manifest ArgoCD actually applied (Step 3) carries argocd.argoproj.io/hook* instead,"
echo "rewritten by cluster/argocd/vendored-widget-kustomize/kustomization.yaml at render time."
```

- [ ] **Step 3: Make the script executable**

```bash
chmod +x scripts/adminapp-vendored.sh
```

- [ ] **Step 4: Run it and confirm the rewrite is visible in what ArgoCD actually applied (requires user confirmation — see Global Constraints)**

Confirm with the user before running.

Run: `./scripts/adminapp-vendored.sh`

Expected: Step 1's output shows `helm.sh/hook` annotations on `vendored-widget-admin-user`; Step 3's output shows `argocd.argoproj.io/hook` annotations on the same Job name instead, with no `helm.sh/hook` present — proving the rewrite happened at render time without editing `chart/vendored-widget`. If Step 2 fails because the AKP repo-server rejects the `helmCharts:` block, re-check Task 7 Step 11 actually applied, and fall back per the design spec's "Known risk" (check in the patched manifest as a plain YAML source) if the hosted repo-server's Kustomize/Helm versions don't support this combination.

- [ ] **Step 5: Add the fourth "Bonus scenario" subsection to `README.md`**

Append after the "### 3. Refactor and repoint at the fixed chart" subsection added in Task 6:

```markdown
### 4. A third-party chart you can't edit

    task adminapp:vendored

`chart/vendored-widget` simulates a chart you pulled from someone else's Helm
repo — same lookup/hooks anti-patterns, but off-limits to edit or fork.
`cluster/argocd/vendored-widget-kustomize/` inflates it with Kustomize's
`helmCharts` generator and patches its Job's `helm.sh/hook*` annotations to
`argocd.argoproj.io/hook*` equivalents at render time (needs
`kustomize.buildOptions: --enable-helm` on the AKP instance — see
`terraform/01-argocd/main.tf`). The script diffs the chart's raw output
against what ArgoCD actually applied to show the rewrite took effect without
touching the chart's source. This fixes ArgoCD's *lifecycle mapping* of the
hook; it does not and cannot fix the vendored Job's own non-idempotent SQL —
that's still out of our hands for code we don't own.
```

- [ ] **Step 6: Commit**

```bash
git add cluster/argocd/vendored-widget-app.yaml scripts/adminapp-vendored.sh README.md
git commit -m "Deploy vendored-widget via the Kustomize hook-rewrite overlay"
```

---

### Task 9: Cleanup, and fold into the existing teardown

**Files:**
- Create: `scripts/adminapp-cleanup.sh`
- Modify: `scripts/teardown.sh`
- Modify: `README.md` (final note on the "Bonus scenario" section)

**Interfaces:**
- Consumes: every Flux/ArgoCD object created in Tasks 4, 5, 6, 8.
- Produces: no `adminapp`/`vendored-widget` Flux or ArgoCD objects, and no `adminapp-demo` namespace. Wired into `task down` (via `scripts/teardown.sh`) so the guestbook scenario's existing teardown covers this scenario too, with no separate lifecycle to remember.

- [ ] **Step 1: Create `scripts/adminapp-cleanup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> Deleting ArgoCD Applications"
# cascade=true is intentional here (unlike the guestbook scenario's rollback
# path, which needs cascade=false to preserve a live workload): this is a
# final teardown, and deleting the underlying resources is the whole point.
argocd app delete adminapp --cascade=true -y 2>/dev/null || true
argocd app delete vendored-widget --cascade=true -y 2>/dev/null || true

echo "==> Deleting Flux objects"
kubectl delete helmrelease adminapp -n flux-system --ignore-not-found
kubectl delete gitrepository adminapp -n flux-system --ignore-not-found

echo "==> Deleting the demo namespace (removes any leftover PVCs/Secrets/Jobs)"
kubectl delete namespace adminapp-demo --ignore-not-found
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/adminapp-cleanup.sh
```

- [ ] **Step 3: Run it and verify everything from this scenario is gone**

Run:
```bash
./scripts/adminapp-cleanup.sh
argocd app list | grep -E 'adminapp|vendored-widget' || echo "no adminapp/vendored-widget Applications remain"
kubectl get namespace adminapp-demo 2>&1 || true
```
Expected: the `argocd app list` grep finds nothing (echoes the fallback message); `kubectl get namespace adminapp-demo` reports it terminating or not found.

- [ ] **Step 4: Wire cleanup into `scripts/teardown.sh`**

Open `scripts/teardown.sh` and add a best-effort call to the new cleanup script, right after the existing probe-cleanup block (`if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then ... fi`) and before the `echo "==> Destroying Terraform-managed AKP resources"` line:

```bash
echo "==> Cleaning up adminapp/vendored-widget demo objects"
./scripts/adminapp-cleanup.sh || echo "WARNING: adminapp-cleanup failed, continuing" >&2
```

- [ ] **Step 5: Verify `task down` still runs cleanly end to end**

Run: `task down`
Expected: the new "Cleaning up adminapp/vendored-widget demo objects" line appears in the output before the Terraform destroy steps; the rest of teardown proceeds exactly as it did before this plan (both `terraform destroy` runs complete, `k3d cluster delete flux-to-argo` succeeds, `.verify/` is removed).

- [ ] **Step 6: Add the closing note to `README.md`**

Append this closing line at the very end of the "Bonus scenario" section (after the "### 4. A third-party chart you can't edit" subsection added in Task 8):

```markdown
`task adminapp:cleanup` removes everything from this scenario on its own if
you want to reset it independently of the guestbook scenario; `task down`
also runs it automatically as part of the full teardown.
```

- [ ] **Step 7: Commit**

```bash
git add scripts/adminapp-cleanup.sh scripts/teardown.sh README.md
git commit -m "Add adminapp/vendored-widget cleanup, folded into task down"
```
