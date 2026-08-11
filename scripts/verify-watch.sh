#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="guestbook-demo"
APP_NAME="guestbook"
POLL_INTERVAL="${WATCH_INTERVAL:-5}"

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "== Watching '${NAMESPACE}' pods, flux-system HelmRelease, ArgoCD Application '${APP_NAME}', and .verify logs =="
echo "== Run this in a second terminal alongside 'task verify:start' — Ctrl-C to stop =="
echo

kubectl get pods -n "${NAMESPACE}" -o wide --watch 2>&1 | sed 's/^/[pods]     /' &
kubectl get helmrelease "${APP_NAME}" -n flux-system --watch 2>&1 | sed 's/^/[flux-hr]  /' &

(
  while true; do
    if json="$(argocd app get "${APP_NAME}" -o json 2>/dev/null)"; then
      echo "[argocd]   sync=$(echo "${json}" | jq -r '.status.sync.status') health=$(echo "${json}" | jq -r '.status.health.status')"
    else
      echo "[argocd]   application '${APP_NAME}' not found"
    fi
    sleep "${POLL_INTERVAL}"
  done
) &

tail -n0 -f .verify/probe.log 2>/dev/null | sed 's/^/[probe]    /' &
tail -n0 -f .verify/pods.log 2>/dev/null | sed 's/^/[pods.log] /' &

wait
