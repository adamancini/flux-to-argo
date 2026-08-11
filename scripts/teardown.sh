#!/usr/bin/env bash
set -euo pipefail

echo "==> Destroying Terraform-managed AKP resources"
terraform -chdir=terraform/03-clusters destroy -auto-approve
terraform -chdir=terraform/01-argocd destroy -auto-approve

echo "==> Deleting k3d cluster"
k3d cluster delete flux-to-argo

rm -rf .verify
