# `terraform/` — reference cloud deploys

**None of this is required to run Career Caddy.** The [quickstart](../README.md) runs
the whole app on one box with `docker compose`. This directory is here so you can see —
and borrow from — how it's run on real cloud infrastructure. It reflects *the
maintainers' choices*; treat it as a worked example, not a prescription.

| Module        | Provider           | Status | What it is |
|---------------|--------------------|--------|------------|
| [`gcp/`](gcp/)         | `hashicorp/google` | **Our production reference** | How the hosted `careercaddy.online` runs today: Cloud Run + Cloud SQL + Artifact Registry, apex-only same-origin routing (no LB), `us-west1`. Deployable. |
| [`aws/`](aws/)         | `hashicorp/aws`    | Community reference (unsupported) | A parallel deploy on ECS Fargate + RDS + ALB, pulling the public GHCR images. Deployable; not what we run. |
| [`generic/`](generic/) | `hashicorp/null`   | Visualization only | A provider-neutral 1:1 of the compose stack, for importing into a diagramming tool (e.g. Brainboard). Never applied. |

Only `gcp/` tracks what's actually in production. `aws/` and `generic/` are kept as
alternatives — a different provider, and a picture of the architecture — precisely so
you're *not* boxed into our stack.

## Secrets & state

Every module keeps secrets out of the tree:

- `*.tfvars` hold your real values (project ids, keys) — only `*.tfvars.example` is
  committed. Copy and fill in locally.
- `*.tfstate` is a plaintext secret store — never local, never committed. Use a remote
  backend (`gcp/` ships a `backend.tf.example` for GCS).
- `.gitignore` at the repo root blocks all of the above.

## Try one without applying

```bash
terraform -chdir=terraform/gcp init -backend=false && terraform -chdir=terraform/gcp validate
terraform -chdir=terraform/aws init -backend=false && terraform -chdir=terraform/aws validate
```

`plan`/`apply` need cloud credentials — see each module's README (`gcp/README.md`,
`aws/`'s header comments). OpenTofu works everywhere Terraform does.
