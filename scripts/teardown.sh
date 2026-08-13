#!/usr/bin/env bash
set -euo pipefail

LOGDIR=".verify"
PIDFILE="${LOGDIR}/probe.pid"
PORT_FORWARD_PIDFILE="${LOGDIR}/port-forward.pid"

echo "==> Stopping any still-running verification probe"
if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
if [[ -f "${PORT_FORWARD_PIDFILE}" ]]; then
  kill "$(cat "${PORT_FORWARD_PIDFILE}")" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PIDFILE}"
fi

echo "==> Cleaning up adminapp/vendored-widget demo objects"
./scripts/adminapp-cleanup.sh || echo "WARNING: adminapp-cleanup failed, continuing" >&2

echo "==> Destroying Terraform-managed AKP resources"
terraform -chdir=terraform/03-clusters destroy -auto-approve \
  || echo "WARNING: terraform/03-clusters destroy failed, continuing" >&2
terraform -chdir=terraform/01-argocd destroy -auto-approve \
  || echo "WARNING: terraform/01-argocd destroy failed, continuing" >&2

echo "==> Deleting k3d cluster"
k3d cluster delete flux-to-argo \
  || echo "WARNING: k3d cluster delete failed, continuing" >&2

rm -rf .verify
