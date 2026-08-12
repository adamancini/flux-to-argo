#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f cluster/flux/adminapp-source.yaml
kubectl apply -f cluster/flux/adminapp-release.yaml

kubectl wait --for=condition=ready --timeout=180s \
  -n flux-system helmrelease/adminapp

kubectl wait --for=condition=available --timeout=180s \
  -n adminapp-demo deployment/adminapp
