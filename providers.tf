# Authenticates via the TFE_TOKEN environment variable (set as a sensitive
# variable on the HCP TF workspace). Hostname defaults to app.terraform.io.
# Organization is set per-resource from the YAML inventory, not here, so the
# factory can manage projects across multiple organizations.
provider "tfe" {}
