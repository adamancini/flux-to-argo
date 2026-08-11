variable "org_name" {
  type        = string
  description = "Akuity organization name"
}

variable "argocd_instance_name" {
  type        = string
  description = "Name of the AKP instance from the 01-argocd stack"
  default     = "flux-to-argo-poc"
}

variable "cluster_name" {
  type        = string
  description = "Name to register the k3d cluster under on the AKP instance"
  default     = "flux-to-argo"
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kubeconfig_context" {
  type    = string
  default = "k3d-flux-to-argo"
}
