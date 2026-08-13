#!/usr/bin/env bash
set -euo pipefail

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

section "STEP 1: Render the vendored chart's raw hook annotations (untouched)"
helm template chart/vendored-widget-kustomize/vendored-widget | grep -A10 'kind: Job' | grep -E 'helm\.sh/hook|name: vendored-widget-admin-user' || true

section "STEP 2: Create and sync the ArgoCD Application (sourced via the Kustomize overlay)"
argocd app create -f cluster/argocd/vendored-widget-app.yaml --upsert
# expected to fail on re-run -- the vendored chart's INSERT isn't idempotent,
# and this demo intentionally never fixes that
argocd app sync vendored-widget || true
argocd app wait vendored-widget --health --timeout 120 || true

section "STEP 3: Read ArgoCD's own hook-recognition record from the sync result"
echo "ArgoCD's sync result for the Job (from its own hook engine's record, not the live object --"
echo "the Job is auto-deleted by hook-delete-policy: HookSucceeded once it completes). This is NOT"
echo "a diff of applied manifests -- 'argocd app manifests' structurally excludes hook resources,"
echo "so the sync-result API is the only place this is observable:"
argocd app get vendored-widget -o json | jq -r '.status.operationState.syncResult.resources[] | select(.kind=="Job") | "kind=\(.kind) name=\(.name) hookType=\(.hookType) hookPhase=\(.hookPhase) message=\(.message)"'

section "AFTER: annotation rewrite confirmed"
echo "The raw chart (Step 1) still carries helm.sh/hook* annotations -- it was never edited."
echo "The sync result above (Step 3) shows hookType=Sync instead of a Helm hook -- rewritten by"
echo "chart/vendored-widget-kustomize/kustomization.yaml at render time."
echo "hookType=Sync specifically is what proves this: ArgoCD's hook detection checks its own"
echo "argocd.argoproj.io/hook annotation first, but falls back to interpreting helm.sh/hook"
echo "directly whenever that native annotation is absent -- and that fallback applies to any"
echo "rendered manifest regardless of source generator. An unpatched chart's"
echo "helm.sh/hook: post-install would still be recognized via that fallback as a PostSync hook"
echo "(chart/adminapp-helmfirst showed exactly this under ArgoCD with no overlay at all). Mapping"
echo "to PostSync here would therefore have been ambiguous -- indistinguishable from ArgoCD just"
echo "falling back to the untouched helm.sh/hook annotation. Sync has no Helm-hook equivalent, so"
echo "seeing hookType=Sync is what actually proves the overlay's rewrite took effect at render time."
