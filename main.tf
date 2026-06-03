locals {
  raw = trimspace(file("${path.module}/projects.yaml"))

  # A blank or all-comment file means "no projects" (yamldecode of "" errors, so
  # we test raw == "" first). A non-blank file that fails to parse is treated as
  # null here and rejected by the terraform_data guard below — so a syntax error
  # halts the run with a clear message rather than crashing inside this local or,
  # worse, silently emptying the inventory (which on apply destroys every
  # project). The null branch also unifies cleanly with the dynamic yamldecode
  # type, where a typed literal would not.
  parseable = local.raw == "" || can(yamldecode(local.raw))
  inventory = local.parseable && local.raw != "" ? yamldecode(local.raw) : null

  # A blank file (null inventory) or a missing/null "projects:" key means no
  # projects. try() reduces a null inventory or absent key to []; a present-but-
  # null key returns null (try only catches errors, not null), handled by the
  # map-level guard below.
  records = try(local.inventory.projects, [])

  # Normalise each record once. Composite org/name key keeps for_each unique if a
  # name repeats across organizations; tostring() coerces YAML scalars into the
  # map(string) shape that tfe_project.tags requires. The guard is applied at the
  # map level because Terraform tuples are length-typed — a ternary mixing an
  # empty and a non-empty tuple fails to unify, whereas empty and non-empty maps
  # unify fine.
  projects = local.records == null ? {} : {
    for p in local.records : "${p.organization}/${p.name}" => {
      organization = p.organization
      name         = p.name
      cost_centre  = tostring(p.cost_centre)
      owner        = tostring(p.owner)
      tags         = { for k, v in try(p.tags, {}) : k => tostring(v) }
    }
  }
}

# Blocking guard: refuse to proceed when projects.yaml exists but does not parse.
# With an unparseable inventory local.projects collapses to {}, which would
# otherwise propose destroying every managed project. terraform_data always has
# one instance, so this precondition is evaluated even when the inventory is
# legitimately empty — unlike a precondition on the for_each resource, which has
# no instances to evaluate when projects is empty.
resource "terraform_data" "validate_inventory" {
  lifecycle {
    precondition {
      condition     = local.parseable
      error_message = "projects.yaml is not valid YAML. Refusing to proceed, because an empty inventory would destroy every managed project. Fix the syntax error and retry."
    }

    # The project name is reused as the OpenShift namespace and the HCP TF project
    # name, so it must be a DNS-1123 label within HCP TF's 40-char project limit.
    precondition {
      condition = alltrue([
        for v in values(local.projects) :
        can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", v.name)) && length(v.name) <= 40
      ])
      error_message = "Every project name must be a valid DNS-1123 label (lowercase alphanumeric and '-') of at most 40 characters, because it is also the OpenShift namespace and HCP TF project name."
    }
  }
}

resource "tfe_project" "this" {
  for_each     = local.projects
  organization = each.value.organization
  name         = each.value.name

  # Formalised tags are merged last so cost_centre and owner always win over any
  # arbitrary tag that reuses those keys.
  tags = merge(
    each.value.tags,
    {
      cost_centre = each.value.cost_centre
      owner       = each.value.owner
    },
  )
}

# Project-scoped variable set exposing project metadata (project name, Vault
# secrets-engine mount) as Terraform variables for workspaces to reuse.
resource "tfe_variable_set" "project" {
  for_each = local.projects

  name              = "${each.value.name}-metadata"
  description       = "Project metadata variables for ${each.value.name}."
  organization      = each.value.organization
  parent_project_id = tfe_project.this[each.key].id
}

resource "tfe_project_variable_set" "project" {
  for_each = local.projects

  project_id      = tfe_project.this[each.key].id
  variable_set_id = tfe_variable_set.project[each.key].id
}

resource "tfe_variable" "project_name" {
  for_each = local.projects

  key             = "project_name"
  value           = each.value.name
  category        = "terraform"
  description     = "Project name (also the OpenShift namespace and Vault role name)."
  variable_set_id = tfe_variable_set.project[each.key].id
}

resource "tfe_variable" "vault_kubernetes_backend" {
  for_each = local.projects

  key             = "vault_kubernetes_backend"
  value           = var.vault_kubernetes_backend
  category        = "terraform"
  description     = "Vault Kubernetes secrets engine mount path for minting OpenShift tokens."
  variable_set_id = tfe_variable_set.project[each.key].id
}
