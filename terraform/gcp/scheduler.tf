# Cloud Scheduler recurring sweeps (CC-213) — replaces the django-q2 `Schedule`
# cron rows the qcluster worker used to own. Cloud Tasks is a queue, not a cron,
# and GCP has no Job runner, so the recurring clock is Cloud Scheduler: each job
# fires on its cron and OIDC-POSTs {"name": "<sweep>"} to the IAM-private `tasks`
# Cloud Run service's /tasks/run-scheduled/ handler, reusing the same
# tasks-invoker SA + service audience already wired in tasks.tf.
#
# CONTRACT with the api handler (job_hunting.lib.schedule_kinds.SCHEDULE_REGISTRY
# + tasks_handlers.run_scheduled_task_handler) — these MUST match exactly:
#   - path:  /tasks/run-scheduled/
#   - body:  {"name": "<sweep-name>"}
#   - names: the keys below == SCHEDULE_REGISTRY's keys.
#
# Sweeps are read/idempotent → at-least-once is safe. This fires ALONGSIDE the
# still-running CC-199 qcluster worker's Schedules until the CC-208 teardown;
# the transient double-fire is harmless (idempotent).

resource "google_project_service" "cloudscheduler" {
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

# name -> cron. Crons mirror the django-q2 Schedule intervals (migration in the
# comment) and the SCHEDULE_REGISTRY interval_seconds on the api side:
#   sweep_stale_scrape_claims    0086  every 5 min
#   federation_dispatch_sweep    0090  every 1 min
#   prune_scrape_html            0109  hourly
#   sweep_stale_unclaimed_holds  0113  every 5 min
locals {
  scheduled_sweeps = {
    sweep_stale_scrape_claims   = "*/5 * * * *"
    federation_dispatch_sweep   = "* * * * *"
    prune_scrape_html           = "0 * * * *"
    sweep_stale_unclaimed_holds = "*/5 * * * *"
  }

  # The /tasks/run-scheduled/ endpoint on the IAM-private tasks service. The
  # OIDC audience for Cloud Run is the bare service URL (no path).
  run_scheduled_url = "${google_cloud_run_v2_service.tasks.uri}/tasks/run-scheduled/"
}

resource "google_cloud_scheduler_job" "sweep" {
  for_each = local.scheduled_sweeps

  name      = "${local.name}-sweep-${replace(each.key, "_", "-")}"
  region    = var.region
  schedule  = each.value
  time_zone = "Etc/UTC"

  # A sweep that overruns its interval must not stack: the handler is
  # idempotent, and Cloud Scheduler retries a failed fire on its own backoff.
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = local.run_scheduled_url
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode(jsonencode({ name = each.key }))

    # Same identity Cloud Tasks uses (tasks.tf) — already granted run.invoker on
    # the tasks service. The audience is the bare Cloud Run service URL.
    oidc_token {
      service_account_email = google_service_account.tasks_invoker.email
      audience              = google_cloud_run_v2_service.tasks.uri
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_service_iam_member.tasks_invoker,
  ]
}

# --- outputs ----------------------------------------------------------------
output "scheduled_sweep_jobs" {
  description = "Cloud Scheduler job names driving the recurring sweeps (CC-213)."
  value       = [for j in google_cloud_scheduler_job.sweep : j.name]
}
