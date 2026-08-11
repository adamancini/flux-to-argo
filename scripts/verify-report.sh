#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="guestbook-demo"
LOGDIR=".verify"
PROBE_LOG="${LOGDIR}/probe.log"
PODS_LOG="${LOGDIR}/pods.log"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then
  kill "$(cat "${PORT_FORWARD_PIDFILE}")" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PIDFILE}"
fi

total=$(wc -l < "${PROBE_LOG}" | tr -d ' ')
failures=$(grep -c FAIL "${PROBE_LOG}" || true)

echo "== Availability =="
echo "requests: ${total}, failures: ${failures}"

echo "== Pod restart counts (max seen per pod) =="
jq -s '
  group_by(.name)
  | map({name: .[0].name, max_restarts: (map(.restarts) | max)})
' "${PODS_LOG}"

echo "== Pod identity stability (distinct pod names per component; should equal replica count) =="
jq -r '.name' "${PODS_LOG}" | sort -u | sed -E 's/-[a-z0-9]+-[a-z0-9]{5}$//' | sort | uniq -c

echo "== Canary entry =="
CANARY="$(cat "${LOGDIR}/canary.txt")"
kubectl -n "${NAMESPACE}" port-forward svc/frontend 8081:80 >/dev/null 2>&1 &
FWD_PID=$!
sleep 2
RESULT="$(curl -sf "http://localhost:8081/guestbook.php?cmd=get&key=canary" || echo 'UNREACHABLE')"
kill "${FWD_PID}" 2>/dev/null || true

if [[ "${RESULT}" == *"${CANARY}"* ]]; then
  echo "canary entry '${CANARY}' PRESENT"
else
  echo "canary entry '${CANARY}' MISSING (got: ${RESULT})"
fi

if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT: PASS (zero failed requests)"
else
  echo "RESULT: FAIL (${failures} failed requests)"
fi
