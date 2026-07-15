# `gcp/` — Career Caddy on Cloud Run (reference)

This is **the config the maintainers run in production** for `careercaddy.online`.
It's here as a worked example — *our* choices, not a requirement. You can run
Career Caddy anywhere the [quickstart](../../README.md) compose stack runs; this
just shows one real, opinionated cloud shape.

Works with both **Terraform** and **OpenTofu** (the `google` provider is identical).

## What it creates

- **Cloud Run** services, one per compose container:
  - `api` (gunicorn; runs migrations on boot), `events` (uvicorn SSE), `frontend`
    (nginx SPA), `mcp` (public MCP), `chat` (internal, IAM-invoked by `api`), and a
    `tasks` handler (same api image, IAM-private, fed by Cloud Tasks).
- **Cloud SQL for PostgreSQL** — reached over the built-in `/cloudsql` socket (no
  VPC connector). Password is generated, never in code.
- **Secret Manager** — `SECRET_KEY`, `DATABASE_URL`, and optional AI keys.
- **Artifact Registry** — one repo holding the mirrored images.
- **Cloud Tasks** — async dispatch queue + IAM wiring.
- **Cloud Run domain mapping** on the apex → the `frontend` service. The frontend
  nginx path-routes `/api`, `/api/v1/events`, and `/mcp` **same-origin** to the
  siblings, so there is **no load balancer and no CORS** — the whole app (incl. the
  public MCP at `<domain>/mcp`) is served on the apex alone.

## Two things GCP makes you do

1. **Mirror the images into Artifact Registry.** Cloud Run cannot pull `ghcr.io`
   directly. After `terraform apply` creates the AR repo, mirror the three public
   GHCR images into it (note the target names use underscores):

   ```bash
   REPO=<ar_region>-docker.pkg.dev/<project_id>/career-caddy
   gcrane cp ghcr.io/overcast-software/career_caddy_api:latest      $REPO/career_caddy_api:latest
   gcrane cp ghcr.io/overcast-software/career-caddy-frontend:latest $REPO/career_caddy_frontend:latest
   gcrane cp ghcr.io/overcast-software/career_caddy_ai:latest       $REPO/career_caddy_ai:latest
   ```

2. **Verify the domain first.** The managed TLS cert only provisions after the apex
   A/AAAA records resolve to Google, and the domain mapping requires the domain be
   verified in Google Search Console under the deploying account.

## Deploy

```bash
# 1. Auth + state backend
gcloud auth application-default login
cp backend.tf.example backend.tf        # edit: your private, versioned GCS bucket
cp terraform.tfvars.example terraform.tfvars   # edit: project_id, domain_name, ...

# 2. Init + apply
terraform init
terraform apply                          # creates AR repo, Cloud SQL, Cloud Run, ...

# 3. Mirror images (see above), then re-apply so services pull successfully
terraform apply

# 4. Point DNS at the mapping, then wait for the cert
terraform output domain_mapping_records  # 4x A + 4x AAAA — set these for host @
```

The cert goes ACTIVE within minutes-to-an-hour after DNS resolves. `.online` is not
HSTS-preloaded, so the site serves over HTTP meanwhile (no hard downtime).

Tear down with `terraform destroy` (all resources default to `deletion_protection =
false` / `ZONAL` Cloud SQL — set `deletion_protection = true` for a real prod box).

## Notes / caveats

- **Frontend upstreams.** The frontend nginx proxies to the deterministic Cloud Run
  URLs `<service>-<project_number>.<region>.run.app`. The project number is looked
  up automatically (`data.google_project.this`) — no manual input — but this assumes
  the standard run.app URL format for your project/region.
- **State = secrets.** State holds the generated DB password + `SECRET_KEY` + the
  full `DATABASE_URL`. Keep it in the private GCS backend; never local, never
  committed. `backend.tf`, `*.tfvars`, and `*.tfstate` are all gitignored.
- **`POSTGRES_16`** is Cloud SQL's newest; the compose db is 18. A real cutover from
  an 18 dump strips the pg17+/pg18-only lines (`\restrict`, `SET transaction_timeout`).
