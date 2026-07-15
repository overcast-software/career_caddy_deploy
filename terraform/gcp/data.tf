# Look up the project's NUMBER (distinct from its id). Cloud Run's deterministic
# run.app URLs use it — <service>-<project_number>.<region>.run.app — and the
# frontend nginx proxies to those (see the API_UPSTREAM/etc. locals). Using a
# data source (not a variable) keeps the module a one-input deploy while avoiding
# a for_each dependency cycle on the Cloud Run services themselves.
data "google_project" "this" {
  project_id = var.project_id
}
