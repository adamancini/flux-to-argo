terraform {
  required_version = ">= 1.5"

  required_providers {
    akp = {
      source  = "akuity/akp"
      version = "~> 0.14"
    }
  }
}

provider "akp" {
  org_name = var.org_name
}

data "akp_instance" "argocd" {
  name = var.argocd_instance_name
}

resource "akp_cluster" "k3d" {
  instance_id = data.akp_instance.argocd.id
  name        = var.cluster_name
  namespace   = "akuity"

  spec = {
    namespace_scoped = false
    description      = "Local k3d cluster for the flux-to-argo migration PoC"

    data = {
      size    = "small"
      project = ""
    }
  }

  kube_config    = local.kube_config
  ensure_healthy = true
}
