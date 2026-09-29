# Troubleshooting Notes

These are the real problems I hit while building this project, in the order they happened. For each one I wrote down what I saw, why it happened, and what fixed it.

The main one (the one I'd pick if asked "tell me about something that broke") is **#4, Cloud Build and the default compute service account**, so it gets the longest write-up.

| # | Area | Problem | Fix (short) |
|---|---|---|---|
| 1 | Tooling | `terraform` not found in Cloud Shell | Installed from HashiCorp apt repo, copied binary to `~/bin` |
| 2 | Git | Push rejected, 117 MB provider file | Fixed `.gitignore`, removed `.terraform/` from the commit |
| 3 | Terraform | `dial tcp [2607:...]:443: cannot assign requested address` | Restarted Cloud Shell; `-refresh=false` when it kept coming back |
| 4 | Cloud Build | Default compute SA had no access to the logs bucket | Ran the build as `cicd-sa`, added `logging.logWriter`, `CLOUD_LOGGING_ONLY` |
| 5 | Logging | Sink IAM binding failed, logging service agent "does not exist" | Created the service identity with `gcloud beta services identity create` |
| 6 | Secret Manager test | 401 `CREDENTIALS_MISSING` / empty output | Root cause: `workloadIdentityUser` binding missing. Binding in `workload-identity.tf`; read test still open |
| 7 | kubectl | `couldn't attach to pod/wi-test` warning | Harmless, the pod finished before attach. Output still printed |
| 8 | Grafana | Wrong data source, confusing error-rate graph, hidden lines | Switched to BigQuery source, changed panel to status counts, reset legend |
| 9 | Security hygiene | `terraform.tfvars` tracked in git, SA key exposed during setup | Untracked tfvars; deleted the exposed key and created a new one |

---

## 1. Terraform is not in Cloud Shell

**What I saw:** `terraform: command not found`.

**Why:** Cloud Shell doesn't come with Terraform. Also, anything installed outside `$HOME` is lost when the Cloud Shell VM is recycled.

**Fix:**
```bash
# add HashiCorp apt repo, then
sudo apt-get update && sudo apt-get install -y terraform
mkdir -p ~/bin && cp "$(which terraform)" ~/bin/
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
```
`$HOME` survives restarts, so the copy in `~/bin` keeps working in new sessions.

---

## 2. GitHub rejected my push (117 MB file)

**What I saw:**
```
remote: error: File terraform/.terraform/providers/registry.terraform.io/hashicorp/google/6.50.0/linux_amd64/terraform-provider-google_v6.50.0_x5 is 116.88 MB; this exceeds GitHub's file size limit of 100.00 MB
 ! [remote rejected] main -> main (pre-receive hook declined)
```

**Why:** `terraform init` downloads the provider binary into `.terraform/`. My `.gitignore` wasn't set up yet, so `git add .` picked it up. Removing the file in a later commit doesn't help, because GitHub checks every commit in the push.

**Fix:**
```bash
# .gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
tfplan
*-key.json

git reset --soft origin/main          # undo my local commits, keep the files
git rm -r --cached terraform/.terraform
git add . && git commit -m "Initial Terraform" && git push
```
**Lesson:** set up `.gitignore` before the first `git add`. The provider gets downloaded again by `terraform init` anyway. What *should* be committed is `.terraform.lock.hcl`, so everyone gets the same provider version.

---

## 3. Cloud Shell IPv6 error during plan/apply

**What I saw:**
```
Error: Error when reading or editing ComputeNetwork "projects/gke-assessment/global/networks/gke-vpc":
Get "https://compute.googleapis.com/...": dial tcp [2607:f8b0:4001:c06::5f]:443: connect: cannot assign requested address
```

**Why:** The Cloud Shell VM tried to reach the Google API over IPv6 and it had no working IPv6 route at that moment. It's a network problem on the Cloud Shell side, not in my Terraform code or in GCP. It happens during the refresh step, where Terraform calls the API for every resource.

**Fix:**
- First time: restarted Cloud Shell (new VM) and re-ran `terraform plan`. It worked and showed no changes.
- When it kept coming back later in long sessions, I used `terraform apply -refresh=false`. This skips reading every existing resource, so there are far fewer API calls. I only did this when I knew nothing had changed outside Terraform. Normally I let it refresh.

**Lesson:** read the error before changing code. The resource name in the message made it look like a VPC problem, but the real clue was `dial tcp [IPv6]`.

---

## 4. Cloud Build could not run (main issue)

**Context:** The clusters have private nodes and I wanted them to pull images only from my own Artifact Registry. So I had to copy `hello-app` and `whereami` into `us-docker.pkg.dev/gke-assessment/apps`.

**Step 1: `docker push` from Cloud Shell didn't work.** The push to Artifact Registry kept failing with connection refused from the Cloud Shell VM. Instead of fighting the local Docker setup, I moved the copy into Cloud Build (`ci/copy-images.cloudbuild.yaml`). That is the better pattern anyway, since the build runs inside GCP with a service account and not from my laptop.

**Step 2: the build itself failed.**
```
ERROR: ... service account <project-number>-compute@developer.gserviceaccount.com
does not have access to the bucket ... (Cloud Build logs bucket)
```

**Why:** When you don't say which service account to use, Cloud Build now defaults to the **Compute Engine default service account**. In my project that account didn't have access to the Cloud Build logs bucket. I also didn't want to use it anyway, because the default compute SA is too powerful and I had already created a dedicated `cicd-sa` in Terraform for this job.

**Fix (three parts):**
1. Run the build as my own SA:
   ```bash
   gcloud builds submit --no-source --config=ci/copy-images.cloudbuild.yaml \
     --service-account=projects/gke-assessment/serviceAccounts/cicd-sa@gke-assessment.iam.gserviceaccount.com
   ```
2. A user-specified build SA must be able to write build logs, so I added `roles/logging.logWriter` to `cicd-sa` in `iam.tf` (next to `artifactregistry.writer` and `container.developer`) and applied.
3. In the build config I set logs to go only to Cloud Logging, so the build doesn't need a logs bucket at all:
   ```yaml
   options:
     logging: CLOUD_LOGGING_ONLY
   ```

**Result:** The build ran, both images landed in Artifact Registry, and the clusters pulled them through `gke-nodes-sa` (which only has `artifactregistry.reader`).

**Lesson:** Always pick the service account for automation yourself, with only the roles it needs. Defaults change between GCP releases and are usually too broad.

---

## 5. Log sink binding failed

**What I saw:** `terraform apply` failed while giving the BigQuery sink writer identity access:
`Service account service-633465245867@gcp-sa-logging.iam.gserviceaccount.com does not exist.`

**Why:** The Cloud Logging service agent for the project is created lazily. It didn't exist yet, so IAM couldn't bind a role to it.

**Fix:**
```bash
gcloud beta services identity create --service=logging.googleapis.com
terraform apply
```
After that the sinks created their tables (`requests`, `stdout`, `events` and others) within a few minutes.

---

## 6. Secret Manager test failed: Workload Identity token

To prove least privilege, I started two short-lived pods, one as `app-b-ksa` (should be allowed) and one as `app-a-ksa` (should be denied). Each one gets a token from the metadata server and calls the Secret Manager API.

**What I saw:** both pods got **401 `CREDENTIALS_MISSING`**, even the app-b one that should have worked. The script said `token length: 622`.

![secret 401](screenshots/troubleshooting/ts-secret-401.png)

Some runs printed nothing at all (curl exit 43):

![secret empty](screenshots/troubleshooting/ts-secret-empty-output.png)

**First guess (wrong):** a trailing newline in the token breaking the `Authorization` header, plus the pod calling the metadata server too early. I added `tr -d "\n"` and `sleep 5`. The result didn't change.

**Digging further:** I printed the raw token response inside the pod:
```
$ kubectl --context primary -n apps run tok-test --rm -i --restart=Never \
    --image=curlimages/curl --overrides='{"spec":{"serviceAccountName":"app-b-ksa"}}' \
    --command -- sh -c 'sleep 5; curl -s -H "Metadata-Flavor: Google" \
    http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token'
Unable to generate access token; IAM returned 403 Forbidden:
This error could be caused by a missing IAM policy binding ...
```
And the IAM policy on the Google SA was empty:
```
$ gcloud iam service-accounts get-iam-policy app-b-sa@gke-assessment.iam.gserviceaccount.com
etag: ACAB
```
gcloud inside the pod failed the same way (`MetadataServerException`).

**Root cause:** the `roles/iam.workloadIdentityUser` binding that lets `apps/app-b-ksa` act as `app-b-sa` was not in place. So the metadata server could not get a token, and my script used the error text as the "token". That was the 622 characters, and it's why Secret Manager said 401.

**Why earlier checks looked fine:** the metadata server returns the service account **email** straight from the KSA annotation. That doesn't need the IAM binding. Only **token** requests do. So my Workload Identity screenshot (the pod shows `app-a-sa`) proved the mapping, not the permission.

**Fix:** the binding in `terraform/workload-identity.tf`:
```hcl
resource "google_service_account_iam_member" "app_wi" {
  for_each           = local.apps
  service_account_id = google_service_account.app[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[apps/${each.key}-ksa]"
}
```
Once it's applied, the token request returns `{"access_token":"ya29...` and the Secret Manager test can be re-run with `gcloud secrets versions access latest --secret=app-b-api-key` from each pod.

**Status:** the end-to-end read test (app-b allowed, app-a denied) is still open.

**Lesson:** 401 means the credential is missing or broken. 403 means the identity is fine but has no permission. And to prove Workload Identity, test that the pod can get a token and call an API, not only that it shows the right email.

---

## 7. `couldn't attach to pod/wi-test` warning

**What I saw:** During the Workload Identity check with `kubectl run --rm -it`:
```
warning: couldn't attach to pod/wi-test, falling back to streaming logs:
... container wi-test not found in pod wi-test_apps
app-a-sa@gke-assessment.iam.gserviceaccount.com
```

![wi attach](screenshots/troubleshooting/ts-wi-attach-warning.png)

**Why:** The pod only runs one `curl` and exits. It finished before `kubectl` could attach to it, so kubectl printed the logs instead.

**Fix:** Nothing to fix. The answer (`app-a-sa@...`) is right there. For a cleaner screenshot I ran it as a small script that prints the identity on its own line (screenshot `12-workload-identity.png`).

---

## 8. Grafana issues

**a) Panel used the wrong data source.** My first panel was pointing at `grafanacloud-...-prom`, the Prometheus that Grafana Cloud creates for you. It has no GKE data, so the panel was empty. I switched the panel to the Google BigQuery data source. For CPU and memory I added a Google Cloud Monitoring data source, because those metrics are not in BigQuery.

**b) The first "error rate %" graph was hard to read.** I first plotted error rate as a percentage per minute. With very low traffic, one failed request out of two shows as 50%, and random 4xx from internet bots made the graph jump between 0 and 100%:

![error rate before](screenshots/troubleshooting/ts-grafana-error-rate-before.png)

I changed it to **stacked bars of request counts per 5 minutes, split by 2xx / 4xx / 5xx**. You can see the volume and the errors together, and the error rate is simply red over the whole bar. The unit also stayed on "percent" after I changed the SQL, so I fixed the panel JSON and re-imported it.

**c) Lines "disappeared".** Clicking a legend item in Grafana shows only that series and hides the rest. That added a "Series hidden" override to my latency and CPU panels. I removed the override (or click the same item again). Ctrl+click toggles one series without hiding the others.

**d) "No data" on pod restarts.** The crashing test pod started after my saved time range ended. I extended the range to 19:15 and saved it as the dashboard default.

---

## 9. Security hygiene

- `terraform.tfvars` was committed before my `.gitignore` rule existed. It held no secrets (project id and group emails), but I removed it from git with `git rm --cached terraform/terraform.tfvars` and kept `terraform.tfvars.example` with placeholders.
- A Grafana service account key was exposed outside the secure path during setup. I deleted that key right away (`gcloud iam service-accounts keys delete ...`), created a new one, entered it only in the Grafana data source settings, and deleted the local key file. Only one active user-managed key remains. In a real setup I'd use Workload Identity Federation so there is no key at all.
