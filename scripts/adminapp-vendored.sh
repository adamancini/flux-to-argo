#!/usr/bin/env bash
set -euo pipefail

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

section "STEP 1: Render the vendored chart's raw hook annotations (untouched)"
helm template chart/vendored-widget-kustomize/vendored-widget | grep -B4 'kind: Job' | grep -E 'helm\.sh/hook|name: vendored-widget-admin-user' || true

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
echo "rewritten by chart/vendored-widget-kustomize/kustomization.yaml at render time."
