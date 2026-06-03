terraform {
  required_version = ">= 1.5.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.77"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.9"
    }
  }
}
