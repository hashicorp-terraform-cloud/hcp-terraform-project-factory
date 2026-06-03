# HCP TF Project Factory

YAML-driven management of HCP Terraform **projects**. The inventory in
[`projects.yaml`](projects.yaml) is the single source of truth: add or edit a
record, commit, and a VCS-managed HCP Terraform workspace reconciles the
projects to match.

## How it works

[`main.tf`](main.tf) `yamldecode`s the inventory, normalises each record, and
drives a single `tfe_project` resource with `for_each`. Two **formalised tags**
— `cost_centre` and `owner` — come from dedicated YAML fields and are always
applied; any additional `tags` map is merged in underneath them. A
`terraform_data` guard rejects an unparseable inventory before any project is
touched (see [Empty & invalid inventory handling](#empty--invalid-inventory-handling)).

```
projects.yaml ──► local.projects ──► tfe_project.this        (for_each)
                                  └─► OpenShift landing zone  (for_each, see below)
```

## Data schema

```yaml
projects:
  - name: payments-platform          # required, 3-40 chars
    organization: 2240368-GBS-Projects  # required — org the project lives in
    cost_centre: "CC-1001"           # required — applied as tag "cost_centre"
    owner: platform-team             # required — applied as tag "owner"
    tags:                            # optional — arbitrary key/value tags
      environment: production
      data_class: confidential
  - name: data-lake
    organization: 2240368-GBS-Projects
    cost_centre: "CC-2002"
    owner: data-eng
    tags: {}                         # may be empty or omitted entirely
```

`organization` is per-record, so one inventory can manage projects across
multiple organizations. The `for_each` key is `<organization>/<name>`, so the
same project name may appear in different organizations.

If an arbitrary `tags` entry reuses the key `cost_centre` or `owner`, the
formalised value wins.

## Empty & invalid inventory handling

The ingestion is deliberately fail-safe, because a project that silently
disappears from the inventory would be **destroyed** on apply:

| `projects.yaml` state | Behaviour |
| --- | --- |
| Blank / all-comment file | Treated as **no projects** (no error) |
| `projects:` key missing or null, or `projects: []` | Treated as **no projects** |
| Malformed / unparseable YAML | **Run is blocked** by the `terraform_data.validate_inventory` precondition, which names the problem — it is *not* silently treated as an empty inventory |

In other words, "the file is empty" is a legitimate no-op, but "the file is
broken" stops the run rather than proposing to delete every managed project.

## OpenShift landing zone

Every managed project also gets a **landing zone** in a single OpenShift cluster
([`landing_zone.tf`](landing_zone.tf)), and the landing zone's credentials are
fed back into the project's HCP TF scope so its workspaces can self-serve:

| Resource | Purpose |
| --- | --- |
| `kubernetes_namespace_v1.this` | The namespace (named after the project). `cost_centre`/`owner` are stored as annotations. |
| `kubernetes_service_account_v1.this` | `tf-admin` — the project's automation identity. |
| `kubernetes_role_binding_v1.admin` | Binds the built-in `admin` ClusterRole to the SA **at namespace scope** (project admin, not cluster-admin). |
| `vault_kubernetes_secret_backend_role.landing_zone` | A role on the `openshift` Vault Kubernetes secrets engine that vends **short-lived** tokens for the `tf-admin` SA, scoped to the project namespace (existing-SA mode). |

### The credential flow

```
factory workspace (its own cluster-admin KUBE_TOKEN) creates, per project:
   namespace + tf-admin SA + admin RoleBinding + Vault role openshift/roles/<project>
        │
        ▼
downstream workspace ──HCP TF Vault dynamic creds──► reads openshift/creds/<project>
        │   Vault calls the cluster TokenRequest API for the tf-admin SA
        ▼
short-lived, namespace-scoped SA token ──► kubernetes provider authenticates
```

The factory keeps its **own** long-lived cluster-admin token (to create namespaces,
service accounts and Vault roles). The **project landing zones no longer store a
token** — each downstream run mints a fresh, short-lived, namespace-scoped token
from Vault. The generic HCP TF↔Vault auth config is delivered to every project by
the org variable set "HCP Vault Provider Auth" (see [`vault_auth.tf`](vault_auth.tf)).

**Prerequisites (owned outside this repo):** the `openshift` engine must be mounted
in Vault namespace `admin` and **configured** (`openshift/config` with the cluster
host/CA and a privileged JWT able to call TokenRequest); the factory workspace needs
Vault dynamic credentials (`TFC_VAULT_*`, namespace `admin`) and a policy allowing
`write openshift/roles/*`. `KUBE_HOST`/CA are assumed present in the downstream scope.

**Next step (tracked in beads):** the downstream *consumption* — a consuming
workspace's `ephemeral "vault_kubernetes_service_account_token"` read of
`openshift/creds/<project>`, which keeps the token out of state and fresh per apply.

### Alternatives considered

- **Long-lived SA token in a project variable set** (the original design) — simplest,
  but a static credential that also sat in Terraform state. Superseded by the Vault
  secrets-engine flow above.
- **OpenShift external OIDC** (HCP Terraform, or Vault, as the cluster's OIDC issuer) —
  would let runs authenticate as OIDC identities, but
  [direct external OIDC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/external-auth)
  **replaces the OAuth server** and permits
  [only one provider](https://github.com/openshift/enhancements/blob/master/enhancements/authentication/direct-external-oidc-provider.md),
  so human SSO and automation cannot coexist. Rejected for a human-serving cluster.
  The Vault **secrets engine** above sidesteps this entirely — it issues ordinary,
  short-lived SA bearer tokens, so OpenShift's own authentication is untouched.

## Running it (VCS-managed workspace)

This configuration is designed to run as a **VCS-managed workspace** in HCP
Terraform, not from a laptop. There is intentionally no `cloud`/backend block —
the workspace association is configured in the HCP TF UI.

1. Push this repository to your VCS (GitHub/GitLab/etc.).
2. In HCP Terraform, create (or locate) the **Management** project.
3. Create a **VCS-managed workspace** in that project pointing at this repo.
4. Add these **sensitive environment variables** (category `env`) on the workspace:
   - `TFE_TOKEN` — scoped to manage projects in every organization referenced in
     `projects.yaml`.
   - `KUBE_HOST` and `KUBE_TOKEN` — the OpenShift API endpoint and a
     **cluster-admin** service-account token (plus CA, e.g. `KUBE_CLUSTER_CA_CERT_DATA`),
     so the factory can create namespaces, service accounts and bindings.
5. Commits to the repo trigger plan/apply runs that reconcile HCP TF projects
   and their OpenShift landing zones to the inventory.

## Local checks

These never contact HCP Terraform and need no token:

```bash
terraform init
terraform fmt -check
terraform validate
```

## Outputs

| Output        | Description                                              |
| ------------- | ------------------------------------------------------- |
| `project_ids` | Map of `<organization>/<name>` to created project ID.   |
