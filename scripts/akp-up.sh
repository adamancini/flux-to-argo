#!/usr/bin/env bash
set -euo pipefail

echo "==> terraform/01-argocd"
terraform -chdir=terraform/01-argocd init
terraform -chdir=terraform/01-argocd apply -auto-approve

ARGOCD_URL="$(terraform -chdir=terraform/01-argocd output -raw argocd_url)"
echo
echo "=============================================================="
echo "ArgoCD instance is up: https://${ARGOCD_URL}"
echo "Log in with:"
echo "  argocd login ${ARGOCD_URL} --grpc-web --username admin"
echo "(password is in terraform/01-argocd/terraform.tfvars)"
echo "=============================================================="
echo

echo "==> terraform/03-clusters"
terraform -chdir=terraform/03-clusters init
terraform -chdir=terraform/03-clusters apply -auto-approve
