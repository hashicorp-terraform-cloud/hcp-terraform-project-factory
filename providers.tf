# Authenticates via the TFE_TOKEN environment variable (set as a sensitive
# variable on the HCP TF workspace). Hostname defaults to app.terraform.io.
# Organization is set per-resource from the YAML inventory, not here, so the
# factory can manage projects across multiple organizations.
provider "tfe" {}

# Cluster-admin access to the OpenShift cluster. host and token come from the
# KUBE_HOST / KUBE_TOKEN env vars; the CA is supplied base64-encoded and decoded
# here (cluster_ca_certificate expects raw PEM).
provider "kubernetes" {
  cluster_ca_certificate = base64decode(var.openshift_ca_cert_base64)
}

# Authenticates via HCP Terraform Vault dynamic credentials (TFC_VAULT_* injected
# on this workspace). Must target the Vault namespace where the "openshift"
# Kubernetes secrets engine is mounted — set TFC_VAULT_NAMESPACE=admin on the
# workspace (or add namespace = "admin" here).
provider "vault" {}
