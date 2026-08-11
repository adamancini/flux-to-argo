#!/usr/bin/env bash
set -euo pipefail

# The HelmRelease never set spec.storageNamespace or spec.releaseName, so
# Flux's helm-controller used its defaults: the release Secret lives in the
# HelmRelease's own namespace (flux-system), not targetNamespace
# (guestbook-demo), under the release name "<targetNamespace>-<chart>"
# (guestbook-demo-guestbook) rather than the chart name.
FLUX_NAMESPACE="flux-system"
HELM_RELEASE_NAME="guestbook-demo-guestbook"

echo "==> Deleting suspended Flux objects"
kubectl delete helmrelease guestbook -n flux-system --ignore-not-found
kubectl delete gitrepository guestbook -n flux-system --ignore-not-found

echo "==> Removing orphaned Helm release secret"
kubectl delete secret -n "${FLUX_NAMESPACE}" \
  -l "owner=helm,name=${HELM_RELEASE_NAME}" --ignore-not-found
