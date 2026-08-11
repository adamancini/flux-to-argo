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

resource "akp_instance" "argocd" {
  name = var.argocd_instance_name

  argocd = {
    spec = {
      version = var.argocd_version
      instance_spec = {
        declarative_management_enabled = true
      }
    }
  }

  argocd_cm = {
    "accounts.admin" = "apiKey,login"
  }

  argocd_secret = {
    "admin.password" = bcrypt(var.admin_password)
  }

  # Known tradeoff: because argocd_secret is ignored below, changing
  # var.admin_password later and re-running `terraform apply` will NOT
  # update the live admin password -- the ignore would need to be removed
  # temporarily (or the password changed another way, e.g. via the
  # argocd/akuity CLI) for a password rotation to take effect.
  lifecycle {
    ignore_changes = [argocd_secret]
  }
}

output "instance_id" {
  value = akp_instance.argocd.id
}

output "argocd_url" {
  description = "ArgoCD API/UI hostname for this instance -- use with 'argocd login'"
  value       = akp_instance.argocd.argocd.spec.instance_spec.fqdn
}
