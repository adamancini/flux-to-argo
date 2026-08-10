#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="flux-to-argo"

if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "k3d cluster '${CLUSTER_NAME}' already exists, skipping create"
else
  k3d cluster create --config cluster/k3d-config.yaml
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"

flux install

kubectl wait --for=condition=available --timeout=120s \
  -n flux-system deployment/source-controller deployment/helm-controller
