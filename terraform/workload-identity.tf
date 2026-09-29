resource "google_service_account_iam_member" "app_wi" {
  for_each           = local.apps
  service_account_id = google_service_account.app[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[apps/${each.key}-ksa]"
}
