# OpenShift landing zone per managed project: a namespace, an admin-scoped
# service account, and a Vault Kubernetes-secrets-engine role that vends
# short-lived tokens for that SA. All resources for_each over the same
# local.projects map and the same "<organization>/<name>" keys as tfe_project.this.

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

# Per-project role on the "openshift" Kubernetes secrets engine (mounted in Vault
# namespace "admin"). Existing-SA mode: Vault vends short-lived tokens for the
# tf-admin service account above, scoped to the project namespace. Downstream
# workspaces read openshift/creds/<project-name> ephemerally at their own run
# instead of inheriting a stored, long-lived KUBE_TOKEN. Referencing the SA's
# name (rather than the literal "tf-admin") makes the role depend on the SA.
resource "vault_kubernetes_secret_backend_role" "landing_zone" {
  for_each = local.projects

  backend                       = "openshift"
  name                          = each.value.name
  allowed_kubernetes_namespaces = [each.value.name]
  service_account_name          = kubernetes_service_account_v1.this[each.key].metadata[0].name
  token_default_ttl             = 3600  # 1h
  token_max_ttl                 = 14400 # 4h
}
