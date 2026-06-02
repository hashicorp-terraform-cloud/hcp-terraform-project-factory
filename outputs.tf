output "project_ids" {
  description = "Map of <organization>/<name> to created HCP TF project ID."
  value       = { for k, p in tfe_project.this : k => p.id }
}

output "landing_zone_namespaces" {
  description = "Map of <organization>/<name> to the OpenShift namespace created for the project."
  value       = { for k, ns in kubernetes_namespace_v1.this : k => ns.metadata[0].name }
}
