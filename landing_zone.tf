# OpenShift landing zone per managed project: a namespace, an admin-scoped
# service account, and that SA's token fed back into the project's HCP TF scope
# as KUBE_TOKEN. All resources for_each over the same local.projects map and the
# same "<organization>/<name>" keys as tfe_project.this.

# The landing zone itself. The project name doubles as the namespace name, so it
# must be a DNS-1123 label (enforced by the guard in main.tf). cost_centre/owner
# are annotations, not labels, because label values reject characters an owner
# email or free-form cost centre may contain.
resource "kubernetes_namespace_v1" "this" {
  for_each = local.projects

  metadata {
    name   = each.value.name
    labels = { "app.kubernetes.io/managed-by" = "hcp-tf-project-factory" }
    annotations = {
      "hcp-tf-project-factory/cost-centre" = each.value.cost_centre
      "hcp-tf-project-factory/owner"       = each.value.owner
    }
  }
}

# The project's automation identity.
resource "kubernetes_service_account_v1" "this" {
  for_each = local.projects

  metadata {
    name      = "tf-admin"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }
}

# Project admin within the namespace — the built-in "admin" ClusterRole bound at
# namespace scope, NOT cluster-admin.
resource "kubernetes_role_binding_v1" "admin" {
  for_each = local.projects

  metadata {
    name      = "tf-admin"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this[each.key].metadata[0].name
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }
}

# Long-lived token for the SA. On Kubernetes/OpenShift >= 1.24 a SA no longer
# auto-mints a token Secret, and a manually-created one is populated
# asynchronously by the token controller — wait_for_service_account_token blocks
# until the token is present so the value below is never read empty.
resource "kubernetes_secret_v1" "sa_token" {
  for_each = local.projects

  metadata {
    name      = "tf-admin-token"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.this[each.key].metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# The loop back into HCP TF: a project-owned variable set, applied to the project,
# carrying just the SA bearer token as the env var the Kubernetes provider reads.
resource "tfe_variable_set" "openshift" {
  for_each = local.projects

  name              = "${each.value.name}-openshift-auth"
  description       = "OpenShift landing-zone admin token for project ${each.value.name}."
  organization      = each.value.organization
  parent_project_id = tfe_project.this[each.key].id
}

resource "tfe_project_variable_set" "openshift" {
  for_each = local.projects

  project_id      = tfe_project.this[each.key].id
  variable_set_id = tfe_variable_set.openshift[each.key].id
}

resource "tfe_variable" "kube_token" {
  for_each = local.projects

  key             = "KUBE_TOKEN"
  value           = kubernetes_secret_v1.sa_token[each.key].data["token"]
  category        = "env"
  sensitive       = true
  description     = "Bearer token for the project's OpenShift namespace-admin service account."
  variable_set_id = tfe_variable_set.openshift[each.key].id
}
