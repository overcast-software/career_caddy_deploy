# Async worker (CC-190) — the django-q2 ``qcluster`` drainer that was DROPPED in
# the 2026-07-14 GCP cutover. AWS (terraform/aws locals.tf `worker`) + the
# generic reference both run a `manage.py qcluster` daemon; GCP shipped without
# one, so EVERY raw django-q2 async_task() call site has been stranded since the
# cutover: parse_scrape_job (extension Sends via /scrapes/from-text/), score_job,
# summaries, resume ingest, JA-match, questions, reextract, federation. Their
# OrmQ rows pile up on django_q_ormq with nothing to drain them.
#
# CC-169 (tasks.tf) only moved the ONE push-shaped path (cover-letter) onto Cloud
# Tasks. Everything else still enqueues via django-q2 async_task and needs a
# resident qcluster to execute. This service restores that drainer.
#
# ── WHY A min-instances=1 SERVICE, NOT A CLOUD RUN JOB / GCE ──────────────────
# qcluster is a CONTINUOUS PULL-LOOP daemon: it polls django_q_ormq forever, it
# is not a request handler and not a batch that exits. That rules out:
#   • A plain (request-billed) Cloud Run service — it scales to zero between
#     requests, and nothing sends it requests, so the loop never runs.
#   • A Cloud Run Job — Jobs run a task to COMPLETION; qcluster never completes.
#     A Scheduler-driven bounded sweep would need an app-side run-once mode
#     django-q2 doesn't cleanly provide, and re-introduces sweep latency.
#   • A Compute Engine container VM — works, but bolts a hand-managed VM (patching,
#     COS, no revision rollout) onto an otherwise all-serverless stack. Rejected
#     unless Doug wants to avoid the shim below.
# A Cloud Run SERVICE with min_instance_count=1 + CPU ALWAYS-ALLOCATED keeps one
# instance resident 24/7 with background CPU, so the qcluster loop runs like the
# Fargate `worker`. Same image, same DB, same secrets/env as `api`.
#
# ── THE ONE APP DEPENDENCY (Doug / cc-api gate) ──────────────────────────────
# Cloud Run REQUIRES the container to answer a startup probe on $PORT. qcluster
# opens NO socket (api/scripts/entrypoint.sh only migrates + runs gunicorn; there
# is no qcluster mode and no health-port shim in the api image). So this service
# as written WILL FAIL its startup probe until the api image ships a tiny
# health-port shim: a command that backgrounds `manage.py qcluster` and serves a
# 200 on $PORT (e.g. a `qcluster-web` entrypoint, ~15 lines). That is a cc-api
# change, filed as the app half of CC-190. The `command` + `startup_probe` below
# are written against that shim's contract; adjust the command to match whatever
# cc-api names it.

resource "google_cloud_run_v2_service" "worker" {
  name                = "worker"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL" # reachable, but no public invoker binding (see below)
  deletion_protection = var.deletion_protection

  template {
    service_account = google_service_account.run.email

    # Resident: exactly one always-on instance runs the pull loop. No autoscaling
    # past 1 — django-q2 Q_WORKERS handles intra-instance concurrency, and a
    # second instance would just double-poll the same OrmQ table.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image = local.images.api

      # Health-port shim (CC-190 app half): background qcluster, serve 200 on $PORT.
      # Placeholder name — align with the cc-api entrypoint once it lands.
      command = ["/app/scripts/qcluster-web.sh"]

      ports {
        container_port = 8000
      }

      resources {
        # CPU ALWAYS allocated — the daemon must keep running BETWEEN requests
        # (there are none). Without this, Cloud Run throttles CPU to ~0 off-request
        # and the pull loop stalls. This is the load-bearing setting for a daemon.
        cpu_idle          = false
        startup_cpu_boost = true
        limits            = { cpu = "1", memory = "1Gi" }
      }

      # qcluster does its own migrate-independence; api owns migrations, so this
      # worker must NOT run them. Mirror the `tasks` service env, minus Cloud Tasks.
      dynamic "env" {
        for_each = merge(local.django_common, {
          GUNICORN_HOST             = "0.0.0.0"
          SA_SCHEMA_ON_POST_MIGRATE = "False"
          SCRAPING_ENABLED          = "False"
          USE_MCP_BROWSER_AGENT     = "False"
          EMAIL_BACKEND             = "django.core.mail.backends.console.EmailBackend"
          SCREENSHOT_DIR            = "/tmp/screenshots"
          Q_WORKERS                 = "2"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = { for k in ["SECRET_KEY", "DATABASE_URL", "OPENAI_API_KEY"] : k => k if contains(keys(local.secret_ids), k) }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = local.secret_ids[env.key]
              version = "latest"
            }
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # The shim serves a plain 200 on $PORT; the probe just proves the process is
      # up (and thus the backgrounded qcluster loop started). Generous failure
      # budget so a slow first migrate-check / import doesn't kill the revision.
      startup_probe {
        http_get {
          path = "/healthz"
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 6
      }
    }
  }

  depends_on = [google_project_service.apis, google_secret_manager_secret_version.app]
}

# NO public invoker IAM binding: this service takes no external traffic. Cloud Run
# still keeps the min-1 instance warm regardless of invoker bindings, and the
# startup probe is internal — so leaving allUsers OFF is correct (unlike the
# lb_services, which need allUsers to be reachable through the LB).
