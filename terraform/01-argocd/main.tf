terraform {
  required_version = ">= 1.5"

  required_providers {
    akp = {
      source  = "akuity/akp"
      version = "~> 0.10"
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

  lifecycle {
    ignore_changes = [argocd_secret]
  }
}

output "instance_id" {
  value = akp_instance.argocd.id
}
