variable "org_name" {
  type        = string
  description = "Akuity organization name"
}

variable "argocd_instance_name" {
  type        = string
  description = "Name of the dedicated AKP instance for this PoC"
  default     = "flux-to-argo-poc"
}

variable "argocd_version" {
  type        = string
  description = "Argo CD version to run on the instance"
  default     = "v2.13.2"
}

variable "admin_password" {
  type        = string
  description = "Local admin password for the AKP instance"
  sensitive   = true
}
