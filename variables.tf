variable "openshift_ca_cert_base64" {
  type        = string
  description = "Base64-encoded PEM CA certificate for the OpenShift API server."
}

variable "vault_kubernetes_backend" {
  type        = string
  description = "Vault Kubernetes secrets engine mount path used to mint OpenShift tokens."
  default     = "openshift"
}
