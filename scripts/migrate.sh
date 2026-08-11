#!/usr/bin/env bash
set -euo pipefail

APP_NAME="guestbook"

echo "==> Creating ArgoCD Application (manual sync)"
argocd app create -f cluster/argocd/guestbook-app.yaml --upsert

echo "==> Diffing before touching Flux"
# argocd app diff exits non-zero both for real drift AND for unrelated
# failures (not logged in, unreachable API, etc.) -- this check can't tell
# the two apart, so the message below covers both.
if ! argocd app diff "${APP_NAME}"; then
  echo "argocd app diff reported a difference (or failed to run — check you're logged in with 'argocd login'). Resolve before suspending Flux. Aborting." >&2
  exit 1
fi

echo "==> Suspending the Flux HelmRelease"
flux suspend helmrelease guestbook -n flux-system

echo "==> Syncing the ArgoCD Application"
argocd app sync "${APP_NAME}"
argocd app wait "${APP_NAME}" --health --timeout 180

echo "==> Promoting to automated sync with self-heal"
argocd app set "${APP_NAME}" --sync-policy automated --auto-prune --self-heal

echo "==> Cutover complete. Flux HelmRelease is suspended (not deleted)."
