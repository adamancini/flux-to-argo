#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f cluster/flux/guestbook-source.yaml
kubectl apply -f cluster/flux/guestbook-release.yaml

kubectl wait --for=condition=ready --timeout=180s \
  -n flux-system helmrelease/guestbook

kubectl wait --for=condition=available --timeout=180s \
  -n guestbook-demo deployment/frontend deployment/redis-leader deployment/redis-follower
