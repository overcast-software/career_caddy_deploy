# Career Caddy — Deploy

Run your own [Career Caddy](https://careercaddy.online) instance.

Career Caddy is an open-source job-hunt manager: you track **job-posts** and the
**applications** you make against them, moving each through stages from *interested*
to *offer*. It's meant to be self-hosted — this repo is how you stand up your own copy.

This is deliberately layered so you're **not locked into our infrastructure choices**:

- **Quickstart (below)** — cloud-agnostic. Everything on one box with `docker compose`,
  using the published images. No cloud account, no Terraform.
- **[`terraform/`](terraform/)** — *reference* cloud deploys. How the maintainers run
  the hosted instance (opinionated: GCP Cloud Run + Cloud SQL). Useful as a worked
  example — **not required**, and not the only way to do it.

---

## Quickstart — one box, five minutes

**Requirements:** Docker + the Docker Compose plugin. That's it.

```bash
git clone https://github.com/overcast-software/career_caddy_deploy.git
cd career_caddy_deploy

cp .env.example .env
# edit .env: set DB_PASSWORD and a real SECRET_KEY
#   python -c "import secrets; print(secrets.token_urlsafe(50))"

docker compose up -d
```

Then open **http://localhost:8080**. On a fresh database you'll land on the **setup
wizard** — create the first admin user (username, email, password). After that you're
in, and you can start adding job-posts and logging applications.

Everything runs on one origin behind a tiny built-in proxy:

| Service    | What it is                                          |
|------------|-----------------------------------------------------|
| `proxy`    | Caddy — serves `http://localhost:8080`, routes `/api/*` to the API, everything else to the SPA |
| `frontend` | The Ember single-page app (published image)         |
| `api`      | Django REST API + Postgres schema (runs migrations on start) |
| `db`       | PostgreSQL 18 (data persists in the `postgres_data` volume) |

Useful commands:

```bash
docker compose logs -f api      # watch the API (and console-logged email)
docker compose pull             # grab newer images
docker compose down             # stop (data volume is kept)
docker compose down -v          # stop AND delete the database volume
```

---

## What works on one box vs. the full service tier

The quickstart runs the **core loop**, and that's the honest scope of it:

**✅ Works out of the gate**
- Create, edit, and organize **job-posts**
- Track **applications** and move them through stages
- Manage your profile / résumé data
- Multi-user setup (invite others; email logs to the container console by default)

**⚙️ Needs the full service tier (not in the quickstart)**
- **Browser scraping** — pulling a job-post from a URL (needs the Camoufox/Playwright
  scrape runner)
- **AI scoring & the chat copilot** — needs an LLM API key and the agent/MCP services
- **Email triage** — turning inbound job emails into posts (the operator-side automation)

You won't get those by default, but the app **functions** without them — you add posts
and applications by hand, which is the whole kick-the-tires experience. Wiring up the
service tier is what the reference deploys in [`terraform/`](terraform/) demonstrate.

---

## Running it in the cloud (optional)

The [`terraform/`](terraform/) directory holds **reference** infrastructure — *the
maintainers' choices, not requirements*:

- **`gcp/`** — how the hosted `careercaddy.online` runs today: Cloud Run + Cloud SQL +
  Artifact Registry (region `us-west1`).
- **`aws/`** — a parallel ECS Fargate + RDS reference.
- **`generic/`** — a provider-neutral diagram of the stack (visualization only).

You're free to ignore all of it and deploy the compose stack above onto any box, or
adapt these as a starting point for your own provider. See
[`terraform/README.md`](terraform/README.md).

---

## License

GPL-3.0 — see [LICENSE](LICENSE).
