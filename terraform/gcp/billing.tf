# Cost visibility: the BigQuery landing zone for Cloud Billing's export, and a
# budget that shouts before the money is gone.
#
# WHY THIS FILE EXISTS
# On 2026-08-17 production went dark. Not an infrastructure fault: a client-side
# loop had been making ~24,000 API calls a day for seven weeks, which drained
# the trial credit, which closed the billing account, which suspended Cloud SQL
# and stopped every Cloud Run service. Two controls were missing, and each one
# alone would have caught it weeks earlier:
#
#   * no cost data anywhere — `bq ls` held only the request-log dataset
#   * no budget. Not "unset": the Budget API had never been enabled on the
#     project, so `gcloud billing budgets list` errored rather than returning
#     an empty list.
#
# THE ONE STEP TERRAFORM CANNOT DO
# Turning ON the Cloud Billing export to BigQuery is a CONSOLE action against
# the BILLING ACCOUNT (Billing -> Billing export -> BigQuery export), not a
# project resource. Verified 2026-08-17 by enumerating the provider's documented
# billing resources: billing_account_iam, billing_budget, billing_project_info,
# billing_subaccount, and the logging_billing_account_* sinks (which route
# billing-account LOGS, not cost data). There is no export resource. This file
# creates the dataset the export writes into and grants read on it; pointing the
# export at that dataset is Doug's console step, once.
#
# ORDER MATTERS: the export is NOT retroactive. It starts collecting the day it
# is switched on, and no history before that can ever be recovered. Enable it
# first, argue about dashboards second.

locals {
  # Same one-boolean-evaluated-once guard as logging.tf.
  billing_export = var.enable_billing_export ? 1 : 0

  # Supplying a billing account id IS the opt-in for the budget — a separate
  # boolean would just be a second thing to forget. Dataset and budget are
  # independent on purpose: either is useful without the other.
  billing_budget = var.billing_account_id != "" ? 1 : 0

  # BigQuery dataset ids allow only letters/digits/underscores.
  billing_dataset_id = "${replace(local.name, "-", "_")}_billing" # career_caddy_billing
}

# --- the export's landing zone ----------------------------------------------

# Co-located with compute (us-west1), mirroring the log dataset. The billing
# export creates and owns its own tables inside this dataset; terraform only
# provides the container, which is why there is no table resource here.
resource "google_bigquery_dataset" "billing" {
  count = local.billing_export

  dataset_id                 = local.billing_dataset_id
  project                    = var.project_id
  location                   = var.region
  labels                     = local.common_labels
  delete_contents_on_destroy = !var.deletion_protection
  description                = "Cloud Billing export (standard usage cost). Populated by the billing account's BigQuery export — enable it in the console; see this file's header."

  depends_on = [google_project_service.bigquery]
}

# Metabase reads cost with the SAME identity it already uses for the request
# logs, so no new key or credential is provisioned. That service account lives
# in logging.tf and only exists when the log export is on — hence both flags in
# this guard. Cost data with no reader is still useful (bq/CLI can query it), so
# a billing export without the log export is allowed; it just isn't wired to BI.
resource "google_bigquery_dataset_iam_member" "billing_reader_view" {
  count = var.enable_billing_export && var.enable_log_export ? 1 : 0

  dataset_id = google_bigquery_dataset.billing[0].dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.bq_reader[0].email}"
}

# --- the budget -------------------------------------------------------------

# Never enabled on this project before now — the API error was the proof.
resource "google_project_service" "billingbudgets" {
  count = local.billing_budget

  project            = var.project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

# Thresholds are deliberately low and early. The failure mode being defended
# against is not "a big bill" — it is "a slow leak nobody sees for five weeks",
# so the FIRST alert matters far more than the last. At the default $50/month
# ceiling the 25% alert lands at $12.50, which a runaway client trips within
# days rather than at zero balance.
#
# Notifications: `all_updates_rule` is deliberately omitted. Cloud Billing
# emails the billing account's admins and users by default, and Doug is both —
# so the default path needs no google_monitoring_notification_channel, no
# Pub/Sub topic, and nothing else to keep working. Add an all_updates_rule with
# monitoring_notification_channels only if these should reach somewhere other
# than that inbox (Slack, PagerDuty).
resource "google_billing_budget" "monthly" {
  count = local.billing_budget

  billing_account = var.billing_account_id
  display_name    = "${local.name} monthly spend"

  # Project NUMBER, not id — from the data source data.tf already provides.
  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.25
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  depends_on = [google_project_service.billingbudgets]
}

# --- outputs (null when off) ------------------------------------------------

output "billing_dataset" {
  description = "BigQuery dataset the Cloud Billing export writes into (null unless enable_billing_export). Point the console's billing export at this."
  value       = var.enable_billing_export ? google_bigquery_dataset.billing[0].dataset_id : null
}

output "billing_budget_name" {
  description = "Resource name of the monthly spend budget (null unless billing_account_id is set)."
  value       = local.billing_budget == 1 ? google_billing_budget.monthly[0].id : null
}
