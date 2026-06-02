# HCP TF Project Factory

YAML-driven management of HCP Terraform **projects**. The inventory in
[`projects.yaml`](projects.yaml) is the single source of truth: add or edit a
record, commit, and a VCS-managed HCP Terraform workspace reconciles the
projects to match.

## How it works

[`main.tf`](main.tf) `yamldecode`s the inventory, normalises each record, and
drives a single `tfe_project` resource with `for_each`. Two **formalised tags**
— `cost_centre` and `owner` — come from dedicated YAML fields and are always
applied; any additional `tags` map is merged in underneath them.

```
projects.yaml ──► local.projects ──► tfe_project.this (for_each)
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

## Running it (VCS-managed workspace)

This configuration is designed to run as a **VCS-managed workspace** in HCP
Terraform, not from a laptop. There is intentionally no `cloud`/backend block —
the workspace association is configured in the HCP TF UI.

1. Push this repository to your VCS (GitHub/GitLab/etc.).
2. In HCP Terraform, create (or locate) the **Management** project.
3. Create a **VCS-managed workspace** in that project pointing at this repo.
4. Add `TFE_TOKEN` as a **sensitive environment variable** on the workspace
   (category `env`). The token must be scoped to manage projects in every
   organization referenced in `projects.yaml`.
5. Commits to the repo trigger plan/apply runs that reconcile HCP TF projects
   to the inventory.

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
