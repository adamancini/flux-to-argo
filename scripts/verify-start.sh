#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="guestbook-demo"
LOGDIR=".verify"
PROBE_LOG="${LOGDIR}/probe.log"
PODS_LOG="${LOGDIR}/pods.log"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

mkdir -p "${LOGDIR}"

if [[ -f "${PIDFILE}" ]]; then
  echo "Probe already running (pid $(cat "${PIDFILE}")). Run 'task verify:report' first." >&2
  exit 1
fi

: > "${PROBE_LOG}"
: > "${PODS_LOG}"

kubectl -n "${NAMESPACE}" port-forward svc/frontend 8080:80 \
  >"${LOGDIR}/port-forward.log" 2>&1 &
echo $! > "${PORT_FORWARD_PIDFILE}"
sleep 2

CANARY="canary-$(date +%s)-$$"
echo "${CANARY}" > "${LOGDIR}/canary.txt"
curl -sf "http://localhost:8080/guestbook.php?cmd=set&key=canary&value=${CANARY}" >/dev/null

(
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if curl -sf -o /dev/null "http://localhost:8080/"; then
      echo "${ts} PASS" >> "${PROBE_LOG}"
    else
      echo "${ts} FAIL" >> "${PROBE_LOG}"
    fi

    kubectl -n "${NAMESPACE}" get pods -l app=guestbook -o json 2>/dev/null \
      | jq -c --arg ts "${ts}" \
        '.items[] | {ts: $ts, name: .metadata.name, created: .metadata.creationTimestamp, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}' \
      >> "${PODS_LOG}"
    kubectl -n "${NAMESPACE}" get pods -l app=redis -o json 2>/dev/null \
      | jq -c --arg ts "${ts}" \
        '.items[] | {ts: $ts, name: .metadata.name, created: .metadata.creationTimestamp, restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}' \
      >> "${PODS_LOG}"

    sleep 1
  done
) &
echo $! > "${PIDFILE}"

echo "Probe started (pid $(cat "${PIDFILE}")). Logs: ${PROBE_LOG}, ${PODS_LOG}"
