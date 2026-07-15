# Secret Manager. DATABASE_URL uses the Cloud SQL unix-socket form so Cloud Run
# connects via the built-in proxy mount at /cloudsql.

locals {
  database_url = "postgresql://postgres:${random_password.db.result}@/job_hunting?host=/cloudsql/${google_sql_database_instance.main.connection_name}"

  secret_values = merge(
    {
      SECRET_KEY   = random_password.secret_key.result
      DATABASE_URL = local.database_url
    },
    var.openai_api_key != "" ? { OPENAI_API_KEY = var.openai_api_key } : {},
    var.anthropic_api_key != "" ? { ANTHROPIC_API_KEY = var.anthropic_api_key } : {},
  )
}

resource "google_secret_manager_secret" "app" {
  # secret NAMES aren't sensitive (only the values are); for_each can't take a
  # sensitive arg, so iterate the key set and unwrap it with nonsensitive().
  for_each  = nonsensitive(toset(keys(local.secret_values)))
  secret_id = "${local.name}-${lower(each.key)}"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "app" {
  for_each       = nonsensitive(toset(keys(local.secret_values)))
  secret           = google_secret_manager_secret.app[each.key].id
  secret_data = local.secret_values[each.key]
}

# key -> secret id, for Cloud Run env value_source.secret_key_ref.
locals {
  secret_ids = { for k, s in google_secret_manager_secret.app : k => s.secret_id }
}
