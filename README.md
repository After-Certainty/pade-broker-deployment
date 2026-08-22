# Deploy a PADE broker on Google Cloud Run

Template for deploying the open-source [PADE](https://github.com/After-Certainty/pade) reference broker.
Fork or clone this repo, fill in `.env` with **your** project identifiers, and use the Make targets to build a runtime overlay and deploy it.

The broker binary comes from the **released GHCR image**. This repo only:

1. Builds a runtime overlay (exec providers + your policy/bindings)
2. Stores durable keys in Google Cloud Secret Manager
3. Deploys the overlay to Cloud Run with those secrets mounted as files

Protocol / identity docs: [cursor-oidc-broker-dogfood.md](https://github.com/After-Certainty/pade/blob/main/docs/cursor-oidc-broker-dogfood.md)
Release: [pade v0.1.1](https://github.com/After-Certainty/pade/releases/tag/v0.1.1)

## Architecture

```text
ghcr.io/after-certainty/pade-broker@v0.1.1  (released; digest-pinned in versions.env)
        +
runtime overlay  (exec providers + rendered policy/bindings → your Artifact Registry)
        +
Google Cloud Run  (-tls-termination=proxy, Secret Manager file mounts)
        +
Cursor Cloud Agent  (provider: broker, short-lived OIDC JWT)
```

The overlay ships PADE reference exec providers (GitHub App installation tokens +
Google OAuth access tokens) plus a **deployment-owned** Vercel provider that
returns static `VERCEL_TOKEN` Material from Secret Manager (Milestone L dogfood —
not PADE core).

Durable authority stays on the broker. The agent receives only Material for the
scoped child execution (`pade exec`).

Do not commit `.env`, PEMs, service-account JSON, or Vercel tokens. Policy/bindings
YAML is rendered at build time from templates + `.env` and is gitignored.

## Image pins

Recorded in [`versions.env`](versions.env). Override any of these in `.env` if you deploy a PADE fork.

| Artifact | Value |
|----------|--------|
| Broker (upstream) | `ghcr.io/after-certainty/pade-broker:v0.1.1` |
| Broker digest | `sha256:6c03d75475e23be9aef7aed867e746ae59cb3c16629e6d264465794fcab175bf` |
| Source commit | `7cecd5e88f74ed47af74a6d09289c7bd1aeac566` |
| Runtime overlay tag | `pade-broker-runtime:${PADE_VERSION}` locally; CI uses full deployment-repo git SHA |

This repo does **not** build `pade-broker` from source. `make build` pulls the
released GHCR image and layers exec providers + rendered config on top.

## Prerequisites

- Docker
- [Google Cloud SDK](https://cloud.google.com/sdk) (`gcloud`), authenticated to a project with billing enabled
- A GitHub App installed on the repos you will expose (`metadata:read`, `contents:read`)
- A Google service account with access to the GA4 property you will expose
- A Vercel access token in Secret Manager for Milestone L (see [docs/milestone-l-vercel.md](docs/milestone-l-vercel.md))
- Network access to pull from `ghcr.io` (public package; no auth required)
- A Cursor Cloud Agent (or other PADE consumer) to obtain your OIDC subject

## Configure `.env`

```bash
cp .env.example .env
```

`.env` holds **non-secret identifiers only**. Never put a private key, token, or SA JSON here.

| Variable | Required | How to obtain |
|----------|----------|----------------|
| `PROJECT_ID` | yes | GCP project id |
| `PROJECT_NUMBER` | no | Looked up from `PROJECT_ID` via `gcloud` |
| `GITHUB_APP_ID` | yes | GitHub → Settings → Developer settings → GitHub Apps |
| `GITHUB_APP_INSTALLATION_ID` | yes | Installation id on the org/account where the App is installed |
| `GITHUB_REPOSITORIES` | yes | Comma-separated `owner/repo` the App may mint tokens for |
| `GA_PROPERTY_ID` | yes | GA4 property resource name, e.g. `properties/123456789` |
| `CURSOR_OIDC_SUBJECT` | yes | From a Cursor Cloud Agent: `pade identity --audience "$(make -s predict-url)"` |
| `BROKER_URL` | no | Defaults to the predicted Cloud Run URL |
| `REGION`, `SERVICE`, image pins | no | Override [`versions.env`](versions.env) defaults |

`CURSOR_OIDC_SUBJECT` uses the **predicted** audience. You can set it before the first deploy; the broker does not need to be up for `pade identity`.

## Quick start

```bash
cp .env.example .env
# edit .env — PROJECT_ID, GitHub App ids, GA property, Cursor subject

make bootstrap-gcp
make predict-url

# Durable keys → Secret Manager (values never printed or committed)
GITHUB_APP_PRIVATE_KEY="$(cat github-app.pem)" make secret-github-app
GOOGLE_ANALYTICS_SA_JSON="$(cat ga-sa.json)" make secret-ga-sa
read -rsp "Vercel token: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
make secret-vercel-token
unset VERCEL_TOKEN

make build    # render config, pull GHCR broker, build runtime overlay
make push
make deploy

make validate-remote
make print-agent-bindings   # copy into the Cursor Cloud Agent
```

## Make targets

| Target | What it does |
|--------|----------------|
| `make bootstrap-gcp` | Enable APIs; create Artifact Registry, runtime SA, IAM |
| `make bootstrap-github-wif` | Deployer SA + GitHub OIDC / WIF pool (admin; rare) |
| `make predict-url` | Print deterministic Cloud Run HTTPS URL |
| `make render-config` | Render policy/bindings from templates + `.env` |
| `make print-agent-bindings` | Print agent YAML pointed at the predicted URL |
| `make pull-broker` | Pull released `ghcr.io/after-certainty/pade-broker` |
| `make build` | Render config; build runtime overlay on the digest-pinned broker |
| `make push` | Push runtime overlay to Artifact Registry |
| `make secret-github-app` | Pipe GitHub App PEM into Secret Manager |
| `make secret-ga-sa` | Pipe GA service account JSON into Secret Manager |
| `make secret-vercel-token` | Pipe Vercel access token into Secret Manager |
| `make deploy` | Deploy runtime image; mount secrets as files |
| `make health` | Stage 2 liveness |
| `make authz-smoke` | Stage 3: unauthenticated `/v1/resolve` → 401 |
| `make logs` | Recent broker Cloud Logging lines |
| `make teardown-docs` | Print teardown commands (does not delete) |
| `make test-providers` | Unit-test deployment-owned exec providers |
| `make validate-remote` | `health` + `authz-smoke` against the deployed URL |

## What this repo builds vs pulls vs mounts

| Component | Source |
|-----------|--------|
| `pade-broker` binary | **Pull** `ghcr.io/after-certainty/pade-broker@sha256:6c03d754…` |
| GitHub + GA exec providers | **Build** from PADE `v0.1.1` tag during `docker build` |
| Vercel exec provider | **Build** from `providers/vercel` in this repo (Milestone L) |
| Policy / bindings | **Render** from `config/*.yaml.tmpl` + `.env`, then copy into the overlay |
| App PEM / SA JSON / Vercel token | **Mount** from Secret Manager at deploy |

## Secret setup

Durable keys go to Google Cloud Secret Manager. Populate them via Make (stdin or env). Do not commit the values.

| Secret Manager id | Mounted at |
|-------------------|------------|
| `github-app-private-key` | `/run/secrets/github-app/private-key.pem` |
| `google-analytics-sa` | `/run/secrets/google-analytics/sa.json` |
| `vercel-token` | `/run/secrets/vercel/token` |

Cloud Run allows one secret volume per mount directory — each secret uses its own subdirectory.

Vercel token walkthrough (UI scope, history-safe capture, metadata-only checks):
[`docs/milestone-l-vercel.md`](docs/milestone-l-vercel.md).

## Capabilities

| Capability | Broker provider | Agent receives | Notes |
|------------|-----------------|----------------|-------|
| `github.repo.read` | `pade-provider-github` (from PADE) | Short-lived `GITHUB_TOKEN` | Reference provider |
| `google-analytics.read` | `pade-provider-google-analytics` (from PADE) | `GA_ACCESS_TOKEN`, `GA_PROPERTY_ID` | Reference provider |
| `vercel.diagnostics` | `pade-provider-vercel` (this repo) | Static `VERCEL_TOKEN` | Milestone L dogfood; opaque id |

Agent-side example: [`agent/broker.bindings.example.yaml`](agent/broker.bindings.example.yaml) or `make print-agent-bindings`.

`vercel.diagnostics` does **not** restrict which Vercel operations the token can
perform after Material delivery — see [docs/milestone-l-vercel.md](docs/milestone-l-vercel.md).

## Validation

See [`docs/validation.md`](docs/validation.md). Stages 4–6 run from a Cursor Cloud Agent.
Milestone L Vercel acceptance is documented in [`docs/milestone-l-vercel.md`](docs/milestone-l-vercel.md).

## Provenance

Cloud Run env vars set at deploy: `PADE_VERSION`, `PADE_REF` (from `versions.env`).
GitHub Actions also sets `DEPLOYMENT_GIT_SHA` to the deployment-repo commit and
tags the overlay image with that full SHA (`RUNTIME_IMAGE_TAG`).

## Teardown

```bash
make teardown-docs
```

## GitHub Actions CI/CD

See [`docs/github-actions.md`](docs/github-actions.md) for CI, production deploy
via Workload Identity Federation, Environment variables, IAM, and rollback notes.
Overlay build only — no PADE source clone for the broker binary.

## Explicitly deferred

Terraform, custom domains, multi-env, building unreleased PADE commits from this repo.
Narrowing the CI deployer from `roles/run.admin` to `roles/run.developer` after
splitting invoker-IAM setup out of routine deploy (documented TODO in
[`docs/github-actions.md`](docs/github-actions.md)).

Milestone M (subject-bound Vercel credentials / Google WIF) scaffolding lives in
this repo — see [`docs/milestone-m-wif.md`](docs/milestone-m-wif.md). Broker
**v0.1.1** ships identity forwarding (ROADMAP #17); live A/B E2E still needs the
operator WIF/secret checklist and an optional binding flip to `subject-secret-wif`.