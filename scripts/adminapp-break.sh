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
