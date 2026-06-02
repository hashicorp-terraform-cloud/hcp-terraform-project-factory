terraform {
  required_version = ">= 1.5.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.77"
    }
  }
}
