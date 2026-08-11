#!/usr/bin/env bash
set -euo pipefail

APP_NAME="guestbook"

echo "==> Creating ArgoCD Application (manual sync)"
argocd app create -f cluster/argocd/guestbook-app.yaml --upsert

echo "==> Diffing before touching Flux"
if ! argocd app diff "${APP_NAME}"; then
  echo "Diff shows drift — resolve before suspending Flux. Aborting." >&2
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
