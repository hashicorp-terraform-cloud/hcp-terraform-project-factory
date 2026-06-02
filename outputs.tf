output "project_ids" {
  description = "Map of <organization>/<name> to created HCP TF project ID."
  value       = { for k, p in tfe_project.this : k => p.id }
}
