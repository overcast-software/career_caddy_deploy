# Alerting on SSE delivery — the failure mode that is invisible from the client.
#
# WHY THIS FILE EXISTS (CC-252, 2026-08-26). The `events` service spent at least
# seven days delivering NOTHING to production while every observable signal said
# it was healthy. The stream returned 200, emitted its `:connected` preamble and
# kept sending keepalives, so the browser's `es.onopen` fired and `events.js` set
# `connected = true`. `pollable.js` silently covered the missing pushes. Nobody
# could have noticed from the outside, and nobody did — it was found by accident
# while writing documentation.
#
# The bug: `_open_listen_connection` resolved the DB host to `localhost` on Cloud
# Run and was refused, so the hub's dispatcher retried at
# `_LISTEN_RECONNECT_BACKOFF_S = 1.0` for as long as any client was subscribed,
# and `events.hub.listen_connected` never appeared once.
#
# THE LESSON THIS ENCODES: connection health and DELIVERY health are independent,
# and only the connection is observable from the client. "Is SSE working in prod?"
# is answered by whether the hub's LISTEN is established — not by an HTTP status,
# not by `events.connected`. This alert watches the signal that actually moves.
#
# WHY THE FAILURE COUNT AND NOT THE ABSENCE OF SUCCESS. The obvious alert is
# "`listen_connected` missing while `stream.start` is present". That is the truer
# statement of the invariant, but absence-of-a-log is a fragile thing to alert on:
# it needs two metrics correlated over a window, and it fires on a quiet night
# when nobody has a tab open. The failure log is a positive signal, is EXACTLY
# zero in a healthy system, and appears within seconds of the fault. It catches
# this bug and every future variant of it (bad credentials, DB unreachable,
# instance without socket access) for a fraction of the complexity.
#
# WHY A THRESHOLD RATHER THAN "ANY OCCURRENCE". A Cloud SQL restart or failover
# produces a short burst of legitimate reconnect failures; the hub is SUPPOSED to
# retry through those. The CC-252 fault produced roughly one per second per
# subscribed instance — about 300 in a five-minute window. Ten in five minutes
# separates "transient blip we recover from" from "wedged and retrying forever"
# with a wide margin on both sides.
#
# OFF BY DEFAULT, like the other optional surfaces in this module: set
# `sse_alert_email` in tfvars to switch it on. Empty (the default) provisions
# nothing, so a bare apply stays lean. The email is a variable rather than a
# literal because THIS IS A PUBLIC REPO — the value lives in the gitignored
# terraform.tfvars, and terraform.tfvars.example shows the shape.

locals {
  # Guard for every resource in this file — one boolean, evaluated once.
  sse_alert = var.sse_alert_email != "" ? 1 : 0

  # The service whose hub we watch. `events` is the ASGI SSE process (see
  # locals.tf lb_services); it is the only place the hub runs in production.
  sse_alert_service = "events"

  # Cloud Logging filter grammar ANDs newline-separated clauses. The hub logs
  # through the `sse_asgi` logger, so the payload substring is stable across
  # revisions — it is the log line's event name, not incidental prose.
  sse_listen_failure_filter = <<-EOT
    resource.type = "cloud_run_revision"
    resource.labels.service_name = "${local.sse_alert_service}"
    textPayload:"events.hub.listen_connect_failed"
  EOT
}

# Cloud Monitoring is only needed when the alert is on.
resource "google_project_service" "monitoring" {
  count = local.sse_alert

  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

# Counts hub LISTEN failures. DELTA/INT64 so an aligner can sum occurrences over
# a window rather than reading an instantaneous gauge — the thing we care about
# is "how many in the last five minutes", not "how many right now".
resource "google_logging_metric" "sse_listen_connect_failed" {
  count = local.sse_alert

  name        = "${local.name}-sse-listen-connect-failed"
  project     = var.project_id
  description = "Count of events.hub.listen_connect_failed on the SSE service. Zero in a healthy system; see CC-252."
  filter      = local.sse_listen_failure_filter

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "SSE hub LISTEN connect failures"
  }
}

# Where the alert goes. An alert policy with no notification channel fires into
# the void — the project had NO channels at all before this file, which is part
# of why CC-252 ran for a week.
resource "google_monitoring_notification_channel" "sse_alert_email" {
  count = local.sse_alert

  project      = var.project_id
  display_name = "Career Caddy prod alerts (email)"
  type         = "email"
  description  = "Operator email for prod alerts. Value set in gitignored tfvars — never a literal in this repo."

  labels = {
    email_address = var.sse_alert_email
  }

  depends_on = [google_project_service.monitoring]
}

# Fires when the hub cannot establish LISTEN and is stuck retrying.
#
# ALIGN_DELTA over a 300s alignment period makes each point "failures in that
# five minutes". `duration = "0s"` means one such point above threshold is enough
# — the condition is already a five-minute aggregate, so adding a duration on top
# would just delay the page by another window.
resource "google_monitoring_alert_policy" "sse_listen_down" {
  count = local.sse_alert

  project      = var.project_id
  display_name = "SSE hub cannot establish LISTEN (delivery is dead)"
  combiner     = "OR"
  user_labels  = local.common_labels

  conditions {
    display_name = "listen_connect_failed > 10 in 5m"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.sse_listen_connect_failed[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sse_alert_email[0].id]

  documentation {
    subject   = "SSE delivery is dead in prod (hub LISTEN failing)"
    mime_type = "text/markdown"
    content   = <<-EOT
      The `events` service cannot open its Postgres LISTEN connection, so **no SSE
      frame is reaching any client** — while every stream still returns 200 and
      keeps sending keepalives. Clients cannot detect this; `pollable.js` masks it.

      **Do not trust an HTTP 200 or `events.connected` as evidence either way.**
      Both were true for the entire seven-day CC-252 outage.

      Check:

      ```
      gcloud logging read 'resource.type="cloud_run_revision"
        AND resource.labels.service_name="events"
        AND textPayload:"listen_connected"' \
        --project=${var.project_id} --freshness=1h --limit=5
      ```

      Zero results while streams are being opened confirms it. Attribute failures
      by `resource.labels.revision_name` before concluding — during a roll, an old
      revision draining its subscribers will keep logging failures while the new
      one is already healthy.

      Prior art: CC-252 (host resolved to `localhost` on Cloud Run because
      `_open_listen_connection` read `HOST` alone, and `dj_database_url` puts the
      Cloud SQL socket in `OPTIONS["host"]`). Subsystem map: claudex
      `api-sse-events-pipeline`.
    EOT
  }

  depends_on = [google_project_service.monitoring]
}

# --- outputs (null when the alert is off) ------------------------------------
output "sse_alert_policy" {
  description = "Name of the SSE LISTEN alert policy (null unless sse_alert_email is set)."
  value       = var.sse_alert_email != "" ? google_monitoring_alert_policy.sse_listen_down[0].name : null
}

# --- api server errors (CC-231) ---------------------------------------------
#
# WHY. During CC-228 the api was returning 500s ("remaining connection slots are
# reserved") and nobody was paged: logfire had ~8 api spans in two days because
# LOGFIRE_TOKEN was never set on the Cloud Run services (see var.logfire_token),
# so the incident had to be dug out of Cloud Logging after a user hit it. This
# alert is the floor that does not depend on logfire being configured at all.
#
# WHAT IT WATCHES. The Cloud Run request log for the `api` service is written by
# the platform for every request, with `httpRequest.status` set — so a 5xx is a
# positive, exactly-zero-when-healthy signal, the same property the SSE alert
# above relies on. It deliberately does NOT use `severity >= ERROR` on the app
# log: Cloud Run stamps everything a container writes to stderr as ERROR, and
# Django's console logger writes INFO lines there, so that filter would page on
# a healthy request. The "remaining connection slots" clause is the CC-228
# signature specifically — Cloud SQL refusing connections shows up in the
# container log before it shows up as a 5xx.
#
# THRESHOLD. Any single 5xx in a five-minute window. The hosted instance serves
# ~zero real users (2026-09 cost-down), so one error is signal, not noise; raise
# the threshold when traffic makes it chatty. Shares the SSE alert's guard and
# email channel — one `sse_alert_email` switches all prod alerting on.

locals {
  api_error_filter = <<-EOT
    resource.type = "cloud_run_revision"
    resource.labels.service_name = "api"
    (
      (logName = "projects/${var.project_id}/logs/run.googleapis.com%2Frequests" AND httpRequest.status >= 500)
      OR textPayload:"remaining connection slots"
    )
  EOT
}

resource "google_logging_metric" "api_server_errors" {
  count = local.sse_alert

  name        = "${local.name}-api-server-errors"
  project     = var.project_id
  description = "Count of 5xx responses from the api service, plus Cloud SQL connection-slot exhaustion lines. Zero in a healthy system; see CC-231 / CC-228."
  filter      = local.api_error_filter

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "api server errors (5xx)"
  }
}

resource "google_monitoring_alert_policy" "api_server_errors" {
  count = local.sse_alert

  project      = var.project_id
  display_name = "api is returning server errors"
  combiner     = "OR"
  user_labels  = local.common_labels

  conditions {
    display_name = "api 5xx > 0 in 5m"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.api_server_errors[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sse_alert_email[0].id]

  documentation {
    subject   = "api is returning 5xx in prod"
    mime_type = "text/markdown"
    content   = <<-EOT
      The `api` Cloud Run service returned at least one server error in the last
      five minutes, or Cloud SQL refused a connection ("remaining connection
      slots are reserved" — the CC-228 signature).

      Find the requests:

      ```
      gcloud logging read 'resource.type="cloud_run_revision"
        AND resource.labels.service_name="api"
        AND httpRequest.status>=500' \
        --project=${var.project_id} --freshness=1h --limit=20
      ```

      If `logfire_token` is set, the exception spans are in Logfire under
      `service_name=career_caddy_api`; if it is not, the traceback is in the
      container log of the same revision (`textPayload`, severity ERROR).

      Prior art: CC-228 (connection-slot exhaustion), CC-231 (this alert).
    EOT
  }

  depends_on = [google_project_service.monitoring]
}

output "api_error_alert_policy" {
  description = "Name of the api 5xx alert policy (null unless sse_alert_email is set)."
  value       = var.sse_alert_email != "" ? google_monitoring_alert_policy.api_server_errors[0].name : null
}
