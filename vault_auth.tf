# Bootstrap: attach the existing organizational variable set "HCP Vault Provider
# Auth" to every managed project, so each project's workspaces inherit the
# HCP TF <-> Vault dynamic-credentials configuration. The variable set already
# exists in HCP TF (varset-XqvvUn1gL571T9x2); this only applies it to projects,
# it does not create or manage the set itself.
#
# Caveat: an organizational variable set belongs to ONE organization. Every
# project this is applied to must live in the org that owns the varset; attaching
# it to a project in a different organization will fail. The factory can span
# multiple orgs (see the local.projects keys, "<org>/<name>"), so add a per-org
# filter or a per-org varset map before any cross-org use.
locals {
  vault_provider_auth_variable_set_id = "varset-XqvvUn1gL571T9x2" # "HCP Vault Provider Auth"
}

resource "tfe_project_variable_set" "vault_auth" {
  for_each = local.projects

  project_id      = tfe_project.this[each.key].id
  variable_set_id = local.vault_provider_auth_variable_set_id
}
