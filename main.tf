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
