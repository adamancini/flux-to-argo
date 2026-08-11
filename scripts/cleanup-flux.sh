#!/usr/bin/env bash
set -euo pipefail

# The HelmRelease never set spec.storageNamespace or spec.releaseName, so
# Flux's helm-controller used its defaults: the release Secret lives in the
# HelmRelease's own namespace (flux-system), not targetNamespace
# (guestbook-demo), under the release name "<targetNamespace>-<chart>"
# (guestbook-demo-guestbook) rather than the chart name.
FLUX_NAMESPACE="flux-system"
HELM_RELEASE_NAME="guestbook-demo-guestbook"

# Guard against running this out of order (before 'task migrate'): if the
# HelmRelease isn't suspended, Flux's helm-controller still owns the release
# and deleting the HelmRelease would trigger its own Helm uninstall, taking
# down the live guestbook instead of just removing dead Flux bookkeeping.
if [[ "$(kubectl get helmrelease guestbook -n "${FLUX_NAMESPACE}" -o jsonpath='{.spec.suspend}' 2>/dev/null)" != "true" ]]; then
  echo "HelmRelease 'guestbook' is not suspended — run 'task migrate' first. Aborting." >&2
  exit 1
fi

echo "==> Deleting suspended Flux objects"
kubectl delete helmrelease guestbook -n "${FLUX_NAMESPACE}" --ignore-not-found
kubectl delete gitrepository guestbook -n "${FLUX_NAMESPACE}" --ignore-not-found

echo "==> Removing orphaned Helm release secret"
kubectl delete secret -n "${FLUX_NAMESPACE}" \
  -l "owner=helm,name=${HELM_RELEASE_NAME}" --ignore-not-found
