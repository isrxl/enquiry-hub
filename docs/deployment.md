# Deployment Guide

Steps to provision infrastructure and deploy the application for the first time.

---

## Prerequisites

| Requirement | Detail |
| --- | --- |
| Azure CLI | `az login` completed with a subscription set |
| Terraform | >= 1.5 |
| GitHub CLI | `gh auth login` completed |
| Azure AD role | **Application Developer** (or `Application.ReadWrite.OwnedBy` with admin consent) — required to create the Entra ID app registration for SWA auth. **This role must be granted to the GitHub Actions service principal**, not just your personal account. |

The Terraform state storage account (`enquiryhubx7qp9mk` in `rg-terraform-state`) must already exist. See the pre-requisites section in `README.md` if it does not.

---

## Step 1 — Set terraform.tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and confirm these values:

| Variable | Required value |
| --- | --- |
| `apim_publisher_email` | Your APIM contact email |
| `alert_email` | Email for Azure Monitor + Sentinel alerts (e.g. `easy@alphaio.com.au`) |

`alert_email` defaults to `admin@example.com` if not set — override it or alerts will go to the wrong address.

---

## Step 2 — Terraform init

```bash
terraform init
```

---

## Step 3 — Terraform apply

```bash
terraform apply
```

> **Note:** APIM takes 30–45 minutes to provision. Plan accordingly.

After apply completes, record the outputs:

```bash
terraform output function_app_name     # e.g. func-enquiryhub-dev
terraform output web_endpoint          # e.g. https://proud-rock-0123.azurestaticapps.net
terraform output apim_gateway_url      # e.g. https://apim-enquiryhub-dev.azure-api.net
```

---

## Step 3 — Update the workflow with the Function App name

Open [.github/workflows/app.yml](../.github/workflows/app.yml) and replace the placeholder on the `app-name` line:

```yaml
# Before
app-name: # TODO: Replace with Terraform output (function_app_name)

# After (example)
app-name: func-enquiryhub-dev
```

Commit and push this change.

---

## Step 4 — Store the SWA deployment token as a GitHub secret

```bash
gh secret set SWA_DEPLOYMENT_TOKEN --body "$(terraform output -raw swa_deployment_token)"
```

This token is used by the `azure/static-web-apps-deploy@v1` action in the workflow. It is marked `sensitive` in Terraform and never printed to the terminal during `terraform apply`.

---

## Step 5 — Grant admin consent (Azure Portal)

If your tenant requires admin approval for delegated API permissions:

1. Go to **Entra ID → App registrations**
2. Open `swa-enquiryhub-staffportal-dev`
3. Go to **API permissions**
4. Click **Grant admin consent for \<your tenant\>**

This is a one-time step. It authorises the `User.Read` (delegated) scope used by the SWA authentication runtime.

---

## Step 6 — Deploy

Push any change under `src/` to `main` to trigger both deploy jobs, or run the workflow manually from the **Actions** tab:

```bash
git push origin main
```

The workflow runs two jobs in sequence:

| Job | Action |
| --- | --- |
| `deploy-functions` | Deploys Python Function App via `Azure/functions-action@v1` |
| `deploy-web` | Deploys static frontend via `azure/static-web-apps-deploy@v1` |

---

## Step 7 — Verify

1. Open the `web_endpoint` URL from Step 2
2. You should be redirected to the Microsoft login page
3. Sign in with a tenant account — you are redirected back to the staff portal
4. Send a test message in the chat UI
5. Check Application Insights for the resulting trace

---

## Re-deployment

Subsequent deployments (code changes only) only require pushing to `main` — no Terraform changes needed. Run `terraform apply` again only when infrastructure changes are made.

---

## Recommended: Enforce PR-only workflow (post-testing)

Once initial setup and testing is complete, configure GitHub branch protection to prevent direct pushes to `main`:

1. Go to **GitHub → Settings → Branches → Add branch ruleset**
2. Target branch: `main`
3. Enable **Require a pull request before merging**
4. Enable **Require status checks to pass** (select the `Terraform` check from `infra.yml`)

This ensures `terraform plan` output is always reviewed in a PR before `terraform apply` runs on merge. The `Terraform Plan (pre-apply)` step in `infra.yml` acts as a safety net during development while direct pushes to `main` are still permitted.
