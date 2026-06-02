# Authenticates via the TFE_TOKEN environment variable (set as a sensitive
# variable on the HCP TF workspace). Hostname defaults to app.terraform.io.
# Organization is set per-resource from the YAML inventory, not here, so the
# factory can manage projects across multiple organizations.
provider "tfe" {}

# Authenticates to the single OpenShift cluster using the cluster-admin service
# account token supplied to this workspace via the KUBE_HOST / KUBE_TOKEN (and
# cluster CA) environment variables — the same env-driven pattern as tfe above.
provider "kubernetes" {}
