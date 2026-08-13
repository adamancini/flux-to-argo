#!/usr/bin/env bash
set -euo pipefail

echo "==> Deleting ArgoCD Applications"
# cascade=true is intentional here (unlike the guestbook scenario's rollback
# path, which needs cascade=false to preserve a live workload): this is a
# final teardown, and deleting the underlying resources is the whole point.
argocd app delete adminapp --cascade=true -y 2>/dev/null || true
argocd app delete vendored-widget --cascade=true -y 2>/dev/null || true

echo "==> Deleting Flux objects"
kubectl delete helmrelease adminapp -n flux-system --ignore-not-found || true
kubectl delete gitrepository adminapp -n flux-system --ignore-not-found || true

echo "==> Deleting the demo namespace (removes any leftover PVCs/Secrets/Jobs)"
# --wait=false: this script often runs right before the whole k3d cluster
# gets deleted anyway (via `task down`), so waiting for namespace
# termination here just adds latency for no benefit.
kubectl delete namespace adminapp-demo --ignore-not-found --wait=false
