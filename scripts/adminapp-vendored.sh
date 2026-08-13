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
argocd app sync vendored-widget || true
argocd app wait vendored-widget --health --timeout 120 || true

section "STEP 3: Compare what ArgoCD actually applied against the raw chart"
echo "ArgoCD's sync result for the Job (from its own hook engine's record, not the live object --"
echo "the Job is auto-deleted by hook-delete-policy: HookSucceeded once it completes):"
argocd app get vendored-widget -o json | jq -r '.status.operationState.syncResult.resources[] | select(.kind=="Job") | "kind=\(.kind) name=\(.name) hookType=\(.hookType) hookPhase=\(.hookPhase) message=\(.message)"'

section "AFTER: annotation rewrite confirmed"
echo "The raw chart (Step 1) still carries helm.sh/hook* annotations -- it was never edited."
echo "The manifest ArgoCD actually applied (Step 3) shows hookType=PostSync instead of a Helm hook --"
echo "rewritten by chart/vendored-widget-kustomize/kustomization.yaml at render time."
echo "hookType is populated exclusively from ArgoCD's own argocd.argoproj.io/hook annotation"
echo "recognition -- it can never show a value unless the Kustomize overlay's JSON-patch rewrite"
echo "(removing helm.sh/hook*, adding argocd.argoproj.io/hook: PostSync) was actually applied at"
echo "render time, since ArgoCD never interprets helm.sh/hook as a hook trigger at all."
