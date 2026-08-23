# GitHub Actions CI/CD

Operating documentation for continuous integration and production deployment of
this broker-deployment repository.

Manual workstation deploys (`make build` / `make push` / `make deploy` /
`make validate-remote`) remain fully supported. GitHub Actions is another caller
of the same Make targets — not a parallel deployment implementation.

## Workflows

| Workflow | File | When | GCP auth |
|----------|------|------|----------|
| **CI** | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | Pull requests; pushes to `master` | None |
| **Deploy production** | [`.github/workflows/deploy-production.yml`](../.github/workflows/deploy-production.yml) | Pushes to `master`; `workflow_dispatch` | GitHub OIDC → WIF → deployer SA |

Default production branch: **`master`**.

---

## 1. CI workflow behavior

CI proves the deployment repo is internally valid and that the runtime overlay
image can be assembled. It does **not** authenticate to Google Cloud, read
Secret Manager, push images, or mutate infrastructure.

Steps (via Make where possible):

1. `shellcheck scripts/*.sh`
2. `make test-providers`
3. Write a **fixture** `.env` (fake identifiers; both `PROJECT_ID` and
   `PROJECT_NUMBER` so scripts never call `gcloud`)
4. `make render-config`
5. `make build` (pull digest-pinned GHCR broker + Docker overlay build)

Permissions: `contents: read` only.

---

## 2. Production deployment behavior

Runs only from `master` (push or manual `workflow_dispatch`), with:

```yaml
concurrency:
  group: pade-broker-production
  cancel-in-progress: false
permissions:
  contents: read
  id-token: write
environment: production
```

A newer push does **not** cancel an in-flight production deploy.

Steps:

1. Checkout
2. `make test-providers`
3. Write `.env` from GitHub Environment **variables** (identifiers only)
4. Authenticate with [`google-github-actions/auth`](https://github.com/google-github-actions/auth) (WIF)
5. Install `gcloud`
6. `make build` / `make push` / `make deploy` / `make validate-remote`
7. Runtime image tag = full git SHA of **this** repository (`RUNTIME_IMAGE_TAG`)

Third-party Actions are pinned to immutable commit SHAs (version noted in
comments). Bump SHAs deliberately when upgrading.

---

## 3. GitHub Environment setup

1. Repo → **Settings** → **Environments** → create **`production`**.
2. Optionally require reviewers for `workflow_dispatch` / protected deploys.
3. Add the variables in the next section (Environment variables, not secrets).
4. Do **not** upload a Google service-account JSON key anywhere in GitHub.

---

## 4. Required GitHub variables

Set on Environment **`production`** (non-secret identifiers):

| Variable | Example / source |
|----------|------------------|
| `GCP_PROJECT_ID` | Your GCP project id |
| `GCP_PROJECT_NUMBER` | Numeric project number (from bootstrap output or Cloud Console) |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full provider resource name printed by `make bootstrap-github-wif` |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | `pade-broker-deployer@PROJECT_ID.iam.gserviceaccount.com` |
| `GH_APP_ID` | GitHub App id (maps to `GITHUB_APP_ID` in `.env`; GitHub forbids vars named `GITHUB_*`) |
| `GH_APP_INSTALLATION_ID` | Installation id |
| `GH_REPOSITORIES` | Comma-separated `owner/repo` list |
| `GA_PROPERTY_ID` | `properties/…` |
| `CURSOR_OIDC_SUBJECT` | Single Cursor OIDC subject allowlisted in broker policy (one-subject deploys) |
| `CURSOR_OIDC_SUBJECTS` | Comma-separated Cursor OIDC subject allowlist (preferred when non-empty) |

Set **at least one** of `CURSOR_OIDC_SUBJECT` or `CURSOR_OIDC_SUBJECTS`. If both are
configured, `CURSOR_OIDC_SUBJECTS` wins — the same precedence as local `.env` and
`make render-config` (see [`scripts/render-config.sh`](../scripts/render-config.sh)).

Optional overrides (only if you diverge from [`versions.env`](../versions.env)):
set matching names in the Environment and extend the workflow `.env` writer.

**Secrets that stay in Google Secret Manager** (never GitHub Secrets for deploy):

| Secret Manager id | Purpose |
|-------------------|---------|
| `github-app-private-key` | GitHub App PEM |
| `google-analytics-sa` | GA service-account JSON |
| `vercel-token` | Optional shared Vercel token (`static-token-file` / Milestone L only; mount via `MOUNT_SHARED_VERCEL_TOKEN=1`). Recommended path uses per-subject secrets — see [`milestone-m-wif.md`](milestone-m-wif.md). |

---

## 5. Two WIF trust paths

This repository uses **two distinct** Workload Identity Federation relationships.
Do not describe them as one shared WIF mechanism.

| Path | Trigger | Pool (default id) | Principal | Purpose |
|------|---------|-------------------|-----------|---------|
| **GitHub Actions → GCP** | CI/CD OIDC | `pade-broker-github` | Deployer SA | Push overlay, deploy Cloud Run |
| **Cursor → GCP** | Runtime OIDC after broker verify | `pade-broker-cursor` | Federated Cursor subject | Subject-bound Secret Manager access for Vercel Material |

```text
GitHub Actions
    ↓ GitHub OIDC
deployment WIF pool/provider
    ↓
Cloud Run deployment authority

Cursor Cloud Agent
    ↓ Cursor OIDC
runtime WIF pool/provider
    ↓
subject-bound Secret Manager authority
```

GitHub Actions workflows configure **only** the deploy path. Cursor runtime WIF is
bootstrapped with `make bootstrap-cursor-wif` and documented in
[`milestone-m-wif.md`](milestone-m-wif.md). Production Environment variables need the
Cursor subject allowlist (`CURSOR_OIDC_SUBJECT` or subjects list) and, for Vercel
subject-secret-wif, per-subject secrets populated outside GitHub (Secret Manager).

Shared Secret Manager id `vercel-token` is optional (Milestone L / `static-token-file`).
Recommended deploys use subject-bound secrets and omit
`MOUNT_SHARED_VERCEL_TOKEN` (default).

### 5a. GitHub Actions → GCP (deploy) WIF architecture


```text
GitHub Actions (master only)
  → GitHub OIDC token (id-token: write)
  → Google Workload Identity Federation provider
  → service account pade-broker-deployer
  → Artifact Registry push + Cloud Run deploy
       ↳ acts as pade-broker-runtime (serviceAccountUser)
       ↳ runtime mounts Secret Manager files
```

| Identity | Name | Responsibility |
|----------|------|----------------|
| Runtime | `pade-broker-runtime` | Cloud Run process identity; reads secrets |
| Deployer | `pade-broker-deployer` | CI/CD push + `gcloud run deploy` only |

No long-lived Google credentials in GitHub. No SA JSON keys.

### Trust restrictions

The OIDC provider attribute condition (defaults for this repo):

```text
assertion.repository_id == '1342370939'
&& assertion.repository_owner_id == '319601927'
&& assertion.ref == 'refs/heads/master'
```

Numeric `repository_id` / `repository_owner_id` are preferred over reclaimable
repository names. Mapped claims include `assertion.sub` → `google.subject` and
`assertion.ref` → `attribute.ref`.

IAM also binds `roles/iam.workloadIdentityUser` on the deployer SA to
`principalSet://…/attribute.repository/After-Certainty/pade-broker-deployment`.

A random repo in the org, a fork, or a non-`master` branch cannot obtain the
production deployer identity through this provider.

Override IDs for a fork when running bootstrap:

```bash
GITHUB_REPOSITORY_ID=… \
GITHUB_REPOSITORY_OWNER_ID=… \
GITHUB_REPOSITORY=owner/repo \
make bootstrap-github-wif
```

---

## 6. Bootstrap commands

One-time (or rare) admin setup on a workstation with project-owner privileges:

```bash
# Existing: APIs, Artifact Registry, runtime SA, local user → runtime SA IAM
make bootstrap-gcp

# Populate Secret Manager (unchanged)
make secret-github-app
make secret-ga-sa
# Optional shared token (static-token-file only):
# make secret-vercel-token
# Subject-bound tokens (recommended):
# SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject

# GitHub Actions: deployer SA + WIF pool/provider + deployer IAM
make bootstrap-github-wif

# Cursor runtime WIF (separate pool; required for subject-secret-wif):
# make bootstrap-cursor-wif
```

`make bootstrap-github-wif` is idempotent. It prints the
`GCP_WORKLOAD_IDENTITY_PROVIDER` and deployer email to copy into GitHub.

Do **not** recreate WIF pools on every deploy. Routine releases only run the
production workflow (or local `make build/push/deploy`).

---

## 7. Service accounts

| Account | Created by | Used by |
|---------|------------|---------|
| `pade-broker-runtime` | `make bootstrap-gcp` | Cloud Run `--service-account` |
| `pade-broker-deployer` | `make bootstrap-github-wif` | GitHub Actions via WIF |

---

## 8. IAM roles (deployer) and why

| Role / binding | Scope | Why |
|----------------|-------|-----|
| `roles/run.admin` | Project | `deploy.sh` passes `--no-invoker-iam-check`, which needs `run.services.setIamPolicy`. `roles/run.developer` is **not** enough for that flag. |
| `roles/artifactregistry.writer` | AR repo `pade` | `make push` |
| `roles/iam.serviceAccountUser` | Runtime SA | Cloud Run deploy `--service-account=pade-broker-runtime@…` |
| `roles/secretmanager.secretAccessor` | Each broker secret (if present) | `--set-secrets` validation at deploy time |
| `roles/iam.workloadIdentityUser` | Deployer SA ← GitHub principal | OIDC federation |

Runtime SA still receives `roles/secretmanager.secretAccessor` from
`bootstrap-gcp` / `secret-*` populate scripts (mount path).

**TODO (later hardening):** split one-time invoker-IAM configuration out of
routine `deploy.sh` so day-to-day CI can use `roles/run.developer` instead of
`roles/run.admin`. Not done in this pass — avoid a deploy-architecture rewrite
solely to drop that role.

Never grant Owner or Editor to the deployer.

---

## 9. Immutable image tagging / provenance

| Layer | Pin |
|-------|-----|
| Upstream broker | `BROKER_IMAGE` + `BROKER_IMAGE_DIGEST` + `PADE_VERSION` / `PADE_REF` in [`versions.env`](../versions.env) |
| Runtime overlay (local default) | `…/pade-broker-runtime:${PADE_VERSION}` |
| Runtime overlay (GitHub Actions) | `…/pade-broker-runtime:<full-git-sha>` via `RUNTIME_IMAGE_TAG` |

Override locally when you want SHA tags:

```bash
RUNTIME_IMAGE_TAG="$(git rev-parse HEAD)" DEPLOYMENT_GIT_SHA="$(git rev-parse HEAD)" \
  make build push deploy
```

Cloud Run also receives `PADE_VERSION`, `PADE_REF`, and (when set)
`DEPLOYMENT_GIT_SHA`.

---

## 10. Manual deployment fallback

From an authenticated workstation (same as before):

```bash
make build
make push
make deploy
make validate-remote
```

Uses `PADE_VERSION` as the image tag unless you set `RUNTIME_IMAGE_TAG`.

---

## 11. Manual `workflow_dispatch`

1. Ensure Environment `production` variables are set and WIF bootstrap is done.
2. GitHub → **Actions** → **Deploy production** → **Run workflow** → branch `master`.
3. Watch the job; concurrency will queue behind any in-flight production deploy.

---

## 12. Troubleshooting WIF / authentication failures

| Symptom | Likely cause |
|---------|----------------|
| `unable to generate access token` / federate errors | Wrong `GCP_WORKLOAD_IDENTITY_PROVIDER` or deployer email in Environment vars |
| `PERMISSION_DENIED` on token exchange | Provider attribute condition rejected the token (wrong repo, fork, or non-`master` ref) |
| `workloadIdentityUser` denied | Bootstrap IAM binding missing; re-run `make bootstrap-github-wif` |
| Works locally, fails in Actions | Local user has broader IAM than deployer SA — compare roles above |
| `setIamPolicy` / invoker check errors | Deployer missing `roles/run.admin` |

Confirm the provider condition and pool:

```bash
gcloud iam workload-identity-pools providers describe github \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool=pade-broker-github
```

Never “fix” auth by uploading an SA JSON key to GitHub Secrets.

---

## 13. Validate a completed deployment

```bash
# From CI (automatic) or locally against the live URL:
make validate-remote
# or:
./scripts/health.sh "https://…"
./scripts/authz-smoke.sh "https://…"
```

Confirm the revision image tag is the expected git SHA and env shows
`DEPLOYMENT_GIT_SHA` / `PADE_VERSION` / `PADE_REF`:

```bash
gcloud run services describe pade-broker --region=us-central1 \
  --format='yaml(spec.template.spec.containers[0].image,spec.template.spec.containers[0].env)'
```

Stages 4–6 (authenticated resolve via Cursor agent) remain manual — see
[`docs/validation.md`](validation.md).

---

## Value classification

| Kind | Where it lives |
|------|----------------|
| Public / non-secret identifiers | `.env` (local), GitHub Environment **variables**, `versions.env` |
| Infrastructure resource names | Printed by bootstrap (`…/workloadIdentityPools/…/providers/github`) |
| Durable secrets | Google Secret Manager only |
| Workflow YAML | No production secrets; no SA keys |

---

## Official references

- [Workload Identity Federation with deployment pipelines](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)
- [`google-github-actions/auth`](https://github.com/google-github-actions/auth)
- Cloud Run invoker IAM check / `roles/run.admin`: [Authenticating public access](https://docs.cloud.google.com/run/docs/authenticating/public)
