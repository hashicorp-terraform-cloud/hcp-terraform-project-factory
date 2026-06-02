locals {
  inventory = yamldecode(file(var.projects_file))

  # Normalise each record once: composite org/name key keeps for_each unique
  # across organizations, and tostring() coerces YAML scalars into the
  # map(string) shape that tfe_project.tags requires.
  projects = {
    for p in local.inventory.projects : "${p.organization}/${p.name}" => {
      organization = p.organization
      name         = p.name
      cost_centre  = tostring(p.cost_centre)
      owner        = tostring(p.owner)
      tags         = { for k, v in try(p.tags, {}) : k => tostring(v) }
    }
  }
}

resource "tfe_project" "this" {
  for_each     = local.projects
  organization = each.value.organization
  name         = each.value.name

  # Formalised tags are merged last so cost_centre and owner always win over
  # any arbitrary tag that reuses those keys.
  tags = merge(
    each.value.tags,
    {
      cost_centre = each.value.cost_centre
      owner       = each.value.owner
    },
  )
}
