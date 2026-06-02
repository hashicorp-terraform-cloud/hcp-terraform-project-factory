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
| `kubernetes_secret_v1.sa_token` | A long-lived `service-account-token` Secret. `wait_for_service_account_token` blocks until the token controller populates it. |
| `tfe_variable_set.openshift` + `tfe_project_variable_set.openshift` | A project-owned variable set, applied to the project. |
| `tfe_variable.kube_token` | The SA token as a sensitive `env` variable `KUBE_TOKEN` in that set. |

### The credential flow

```
cluster-admin token (KUBE_HOST/KUBE_TOKEN env on THIS workspace)
        │  factory authenticates to OpenShift
        ▼
namespace + tf-admin SA (namespace-admin) ──► long-lived SA token
        │
        ▼
project-scoped variable set: KUBE_TOKEN (sensitive env)
        │  inherited by every workspace in the HCP TF project
        ▼
downstream workspace's kubernetes provider authenticates to its own namespace
```

`KUBE_HOST` (the API endpoint) and the cluster CA are assumed to be present
already in the downstream scope; this factory only supplies `KUBE_TOKEN`.

> **Note:** the stored token is a **long-lived, static** service-account token —
> it does not expire, which keeps the variable set valid indefinitely but means
> it does not rotate on its own. The factory authenticates to OpenShift with a
> cluster-admin SA token provided to its own workspace as `KUBE_HOST`/`KUBE_TOKEN`.

### Authentication decision: why a long-lived token, not dynamic credentials

[HCP Terraform dynamic provider credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/kubernetes-configuration)
(workload-identity / OIDC) would remove the stored token entirely — each run mints
a short-lived OIDC JWT instead. We evaluated it and **deliberately did not adopt
it**, because on OpenShift it requires
[direct external OIDC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/external-auth),
which:

- **replaces the built-in OAuth server**, breaking htpasswd/LDAP/SSO and `oc login`
  password flows for human users;
- allows [**at most one** external OIDC provider](https://github.com/openshift/enhancements/blob/master/enhancements/authentication/direct-external-oidc-provider.md),
  so human SSO and HCP Terraform cannot coexist;
- leaves humans with only a break-glass client certificate.

This cluster serves human users via OAuth, so that trade-off is unacceptable.
**Revisit only if** (a) a cluster *dedicated to automation* (no human login)
becomes available, or (b) OpenShift gains multi-issuer external OIDC so human
OAuth and HCP Terraform can run side by side.

#### Candidate future architecture: Vault as the single OIDC issuer

The single-provider limit can be worked around by making **Vault** the one OIDC
issuer OpenShift trusts, fronting *both* humans and automation:

- **Humans** authenticate to Vault (any auth method) and receive Vault-signed
  tokens OpenShift accepts.
- **Automation** presents its HCP TF workload-identity JWT to a Vault JWT auth
  mount (`bound_issuer = https://app.terraform.io`), then mints a Vault identity
  OIDC token (`iss = Vault`, `aud = openshift`) used as `KUBE_TOKEN`. No stored
  secret.

This is secretless *and* keeps human access, but it is a **platform-level
commitment**, not a change scoped to this factory: Vault becomes critical-path
for all cluster auth, the OAuth→external-OIDC bootstrap still applies (now
fronted by Vault), this config would grow a `vault` provider plus per-project
Vault resources, and humans need a credential-exec helper so they share the same
Vault issuer the automation uses.

Note: the [native HCP TF Kubernetes dynamic-credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/kubernetes-configuration)
flow does **not** enable this — its token is signed by HCP TF
(`iss = app.terraform.io`) and never passes through Vault, so a Vault-trusting
cluster rejects it. That flow is only for end-state (a) above, where OpenShift
trusts HCP Terraform directly. Tracked in the backlog for if/when Vault fronts
cluster auth.

**Token-in-state constraint:** the Vault→OpenShift token exchange must **not** be
a normal `data "vault_identity_oidc_token"` read — that persists the token in
state and freezes a plan-time token a short TTL invalidates before apply. It
requires an **ephemeral resource** (Terraform 1.10+: never in state, opened at
apply, can feed the kubernetes provider's `token`) — confirm an *ephemeral*
identity-oidc-token resource exists in the Vault provider, or mint the token
outside Terraform (agent hook / `exec` plugin). The same state exposure applies
to the **current** design — `kubernetes_secret_v1.sa_token.data` and
`tfe_variable.kube_token.value` are in state today; ephemeral reads and
write-only (`*_wo`) attributes would harden it.

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
