#!/usr/bin/env bash
set -euo pipefail

for stack in terraform/01-argocd terraform/03-clusters; do
  echo "==> ${stack}"
  terraform -chdir="${stack}" init
  terraform -chdir="${stack}" apply -auto-approve
done
