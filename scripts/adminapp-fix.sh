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
  if ! json="$(argocd app get "${APP_NAME}" -o json 2>/dev/null)"; then
    echo "--- argocd: application '${APP_NAME}' not found ---"
    return
  fi
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

section "STEP 2: First sync on the refactored chart"
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
echo "(idempotent INSERT OR IGNORE)."
echo
echo "Note: the OLD job/adminapp-admin-user from the helmfirst chart is still present below,"
echo "even with --prune on both syncs above -- this is expected, not a bug. ArgoCD's standard"
echo "prune mechanism does not delete Helm hook resources; a hook's lifecycle is governed only"
echo "by its own helm.sh/hook-delete-policy, and this Job's policy (hook-succeeded) never fires"
echo "because it Failed, not Succeeded. This is the same 'hook resources aren't managed with"
echo "corresponding releases' problem the design spec cites from Helm's own docs -- it's still"
echo "true even after switching to a chart that no longer defines the hook at all. It's inert"
echo "(Failed, not blocking anything), and 'task adminapp:cleanup'/'task down' remove it along"
echo "with everything else in the namespace regardless:"
kubectl get job adminapp-admin-user -n "${NAMESPACE}" 2>&1 || echo "job/adminapp-admin-user not found"
