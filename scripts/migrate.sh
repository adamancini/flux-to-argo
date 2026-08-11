#!/usr/bin/env bash
set -euo pipefail

APP_NAME="guestbook"

section() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
}

flux_state() {
  echo "--- flux: helmrelease 'guestbook' (flux-system) ---"
  flux get helmrelease guestbook -n flux-system 2>&1 || true
}

argocd_state() {
  local json
  if ! json="$(argocd app get "${APP_NAME}" -o json 2>/dev/null)"; then
    echo "--- argocd: application '${APP_NAME}' not found ---"
    return
  fi
  echo "--- argocd: application '${APP_NAME}': sync=$(echo "${json}" | jq -r '.status.sync.status') health=$(echo "${json}" | jq -r '.status.health.status') ---"
}

section "BEFORE: Flux owns the guestbook; the ArgoCD Application doesn't exist yet"
flux_state
argocd_state

section "STEP 1: Create the ArgoCD Application (manual sync)"
argocd app create -f cluster/argocd/guestbook-app.yaml --upsert
argocd_state

section "STEP 2: Diff before touching Flux (expect no meaningful drift)"
# argocd app diff exits non-zero both for real drift AND for unrelated
# failures (not logged in, unreachable API, etc.) -- this check can't tell
# the two apart, so the message below covers both.
if ! argocd app diff "${APP_NAME}"; then
  echo "argocd app diff reported a difference (or failed to run — check you're logged in with 'argocd login'). Resolve before suspending Flux. Aborting." >&2
  exit 1
fi
echo "no unexpected drift — safe to proceed"

section "STEP 3: Suspend the Flux HelmRelease (rollback point — not deleted)"
flux suspend helmrelease guestbook -n flux-system
flux_state

section "STEP 4: Sync the ArgoCD Application in place"
argocd app sync "${APP_NAME}"
argocd app wait "${APP_NAME}" --health --timeout 180
argocd_state

section "STEP 5: Promote to automated sync with self-heal"
argocd app set "${APP_NAME}" --sync-policy automated --auto-prune --self-heal
argocd_state

section "AFTER: cutover complete"
echo "Flux HelmRelease is suspended, not deleted (still there for rollback):"
flux_state
echo
echo "ArgoCD now owns the guestbook via automated sync + self-heal:"
argocd_state
