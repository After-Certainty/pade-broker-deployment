# Deploy a PADE broker on Google Cloud Run

Template for deploying the open-source [PADE](https://github.com/After-Certainty/pade) reference broker.
Fork or clone this repo, fill in `.env` with **your** project identifiers, and use the Make targets to build a runtime overlay and deploy it.

The broker binary comes from the **released GHCR image**. This repo only:

1. Builds a runtime overlay (exec providers + your policy/bindings)
2. Stores durable keys in Google Cloud Secret Manager
3. Deploys the overlay to Cloud Run with those secrets mounted as files

Protocol / identity docs: [cursor-oidc-broker-dogfood.md](https://github.com/After-Certainty/pade/blob/main/docs/cursor-oidc-broker-dogfood.md)
Release: [pade v0.2.1](https://github.com/After-Certainty/pade/releases/tag/v0.2.1)
Roadmap (Milestones L–O): [ROADMAP.md](https://github.com/After-Certainty/pade/blob/main/ROADMAP.md)

## Responsibility split

| Layer | Owns | Does not own |
|-------|------|----------------|
| **PADE core** | Portable capability intent, Broker/Consumer contracts, generic Material, broker-verified identity context for trusted broker-side exec providers (v0.1.1) | Vercel (or other vendor) providers, schemas, SDKs, CLIs, or user→secret tables |
| **This deployment repo** | Concrete policy/bindings, deployment-owned exec providers, Cloud Run + Secret Manager layout, GitHub deploy WIF, Cursor runtime WIF, IAM, Vercel fulfillment | PADE protocol changes; durable credentials on the agent VM |
| **Consumer / Cloud Agent** | Ordinary vendor tools (e.g. Vercel CLI) under released PADE tooling (`pade exec`); receives Material only for scoped children | Durable App keys, SA JSON, or Vercel tokens on the VM |

A new reader should **not** conclude that PADE itself contains a Vercel provider. Vercel fulfillment lives only under [`providers/vercel/`](providers/vercel/) in this repository.

## Architecture

```text
ghcr.io/after-certainty/pade-broker:v0.2.1  (released; digest-pinned in versions.env)
        +
runtime overlay  (exec providers + rendered policy/bindings → your Artifact Registry)
        +
Google Cloud Run  (proxy TLS termination, Secret Manager file mounts)
        +
Cursor Cloud Agent  (provider: broker, short-lived OIDC JWT)
```

### Recommended Vercel path (`fulfillment: subject-secret-wif`)

```text
Cursor workload identity (OIDC JWT)
        ↓
PADE broker verifies + authorizes
        ↓
trusted deployment-owned exec provider
        ↓
Google STS / Cursor→GCP WIF
        ↓
subject-specific Google principal
        ↓
Secret Manager IAM
        ↓
subject-specific Vercel token
        ↓
generic PADE Material { env: { VERCEL_TOKEN: "…" } }
        ↓
ordinary Vercel CLI
```

The provider derives the subject-specific Secret Manager id **deterministically** from the verified subject (hash prefix). That naming convention is **not** authorization. Google IAM on the federated principal is the authorization boundary. Before federation, the provider validates that `identity.subject` matches the `sub` claim of the forwarded `idToken` when both are present.

### Two WIF trust paths (do not conflate)

```text
GitHub Actions
    ↓ GitHub OIDC
deployment WIF pool/provider (pade-broker-github)
    ↓
Cloud Run deployment authority (deployer SA)

Cursor Cloud Agent
    ↓ Cursor OIDC
runtime WIF pool/provider (pade-broker-cursor)
    ↓
subject-bound Secret Manager authority (federated principal per subject)
```

| Path | Identity | Purpose |
|------|----------|---------|
| **GitHub Actions → GCP** | GitHub OIDC → deployer SA | CI/CD: push overlay, deploy Cloud Run |
| **Cursor → GCP** | Cursor OIDC (broker-verified) → federated subject | Runtime: subject-bound Secret Manager access for Vercel Material |

### Runtime service account vs federated subject

| Authority | Holder |
|-----------|--------|
| Mounted GitHub App PEM + GA SA JSON | Cloud Run **runtime** service account (Secret Manager accessor on those secrets) |
| Optional shared `vercel-token` mount | Runtime SA — **only** when `MOUNT_SHARED_VERCEL_TOKEN=1` (static-token-file / Milestone L) |
| Per-subject `vercel-token-sub-*` secrets | **Federated Cursor subject** principals via Cursor WIF — **not** the runtime SA |

A normal Milestone M-style deploy does **not** require the shared Vercel token mount.

### PADE v0.1.1 identity seam

The broker already verified the workload identity. A trusted broker-side exec provider may receive that verified identity context so it can participate in downstream federation:

- broker-side only, after verify + authorize
- exact presented ID token + verified subject
- **not** portable Intent, **not** consumer configuration, **not** a PADE user database
- does **not** make PADE an identity provider or introduce vendor identity semantics into PADE

See upstream [`docs/provider-contract.md`](https://github.com/After-Certainty/pade/blob/v0.1.1/docs/provider-contract.md).

### Static-token-file vs subject-secret-wif

| Mode | Role |
|------|------|
| **`subject-secret-wif`** (template default) | Recommended production / dogfood path: subject-bound downstream authority |
| **`static-token-file`** | Milestone L proof and optional compatibility / local / fallback: one shared deployment-owned token |

When `fulfillment` is omitted in provider config, the Go provider falls back to `static-token-file` for compatibility. Deployed bindings in this repo **always set** `fulfillment: subject-secret-wif`.

`MOUNT_SHARED_VERCEL_TOKEN=1` is required only for static-token-file (shared Cloud Run mount). Subject-secret-wif does not use that mount.

### What the dogfood proved

Milestones **L–O are complete** (see PADE ROADMAP). Architecturally:

- Vendor integrations can remain deployment-owned; PADE need not grow a Vercel provider
- Generic Material was sufficient for ordinary CLI use
- The external-provider / exec seam worked
- One generic gap (broker-verified identity for trusted exec) was fixed in **v0.1.1**
- Downstream IAM can provide per-subject authority without PADE maintaining user→secret mappings
- Milestone O concluded there is currently **no** justification for additional PADE protocol work

## Image pins

Recorded in [`versions.env`](versions.env). Override in `.env` only if you deploy a PADE fork.

| Artifact | Value |
|----------|--------|
| Broker (upstream) | `ghcr.io/after-certainty/pade-broker:v0.2.1` |
| Broker digest | `sha256:3a17bcd0867e7666870d5e54e42b3cf6a39444d0c5227768fbe3baff0ae353af` |
| Source commit | `d50174a2696743db3879dc98615801f5ad8d462a` |
| Runtime overlay tag | `pade-broker-runtime:${PADE_VERSION}` locally; CI uses full deployment-repo git SHA |

This repo does **not** build `pade-broker` from source. `make build` pulls the released GHCR image and layers exec providers + rendered config on top.

## Prerequisites

- Docker
- [Google Cloud SDK](https://cloud.google.com/sdk) (`gcloud`), authenticated to a project with billing enabled
- A GitHub App installed on the repos you will expose (`metadata:read`, `contents:read`)
- A Google service account with access to the GA4 property you will expose
- For recommended Vercel path: Cursor WIF bootstrap + per-subject Vercel tokens in Secret Manager (see [docs/milestone-m-wif.md](docs/milestone-m-wif.md))
- Optional: shared Vercel token + `MOUNT_SHARED_VERCEL_TOKEN=1` for static-token-file only ([docs/milestone-l-vercel.md](docs/milestone-l-vercel.md))
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
| `CURSOR_OIDC_SUBJECT` | yes* | From a Cursor Cloud Agent: `pade identity --audience "$(make -s predict-url)"` |
| `CURSOR_OIDC_SUBJECTS` | no | Comma-separated subjects for A/B isolation dogfood (overrides single subject) |
| `BROKER_URL` | no | Defaults to the predicted Cloud Run URL |
| `REGION`, `SERVICE`, image pins | no | Override [`versions.env`](versions.env) defaults |

\* Or set `CURSOR_OIDC_SUBJECTS`. Audience uses the **predicted** URL; the broker need not be up for `pade identity`.

## Quick start (recommended: subject-secret-wif)

```bash
cp .env.example .env
# edit .env — PROJECT_ID, GitHub App ids, GA property, Cursor subject(s)

make bootstrap-gcp
make predict-url
make bootstrap-cursor-wif   # once per project; allowed audiences = broker URL

# Durable keys → Secret Manager (values never printed or committed)
GITHUB_APP_PRIVATE_KEY="$(cat github-app.pem)" make secret-github-app
GOOGLE_ANALYTICS_SA_JSON="$(cat ga-sa.json)" make secret-ga-sa

# Per-subject Vercel tokens (IAM to federated principal, not runtime SA)
read -rsp "Vercel token for subject A: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
SUBJECT='user:SUBJECT_A' make secret-vercel-token-subject
unset VERCEL_TOKEN
# repeat SUBJECT=… for each allowlisted subject

make build    # render config, pull GHCR broker, build runtime overlay
make push
make deploy   # omits shared vercel-token mount by default

make validate-remote
make print-agent-bindings   # copy into the Cursor Cloud Agent
```

For the optional shared-token path instead, see [docs/milestone-l-vercel.md](docs/milestone-l-vercel.md) (`make secret-vercel-token` + `MOUNT_SHARED_VERCEL_TOKEN=1` + static-token-file binding).

## Make targets

| Target | What it does |
|--------|----------------|
| `make bootstrap-gcp` | Enable APIs; create Artifact Registry, runtime SA, IAM |
| `make bootstrap-github-wif` | Deployer SA + GitHub OIDC / WIF pool (admin; rare) |
| `make bootstrap-cursor-wif` | Cursor OIDC → GCP WIF pool (runtime subject-bound authority) |
| `make predict-url` | Print deterministic Cloud Run HTTPS URL |
| `make render-config` | Render policy/bindings from templates + `.env` |
| `make print-agent-bindings` | Print agent YAML pointed at the predicted URL |
| `make pull-broker` | Pull released `ghcr.io/after-certainty/pade-broker` |
| `make build` | Render config; build runtime overlay on the digest-pinned broker |
| `make push` | Push runtime overlay to Artifact Registry |
| `make secret-github-app` | Pipe GitHub App PEM into Secret Manager |
| `make secret-ga-sa` | Pipe GA service account JSON into Secret Manager |
| `make secret-vercel-token` | Pipe shared Vercel token (static-token-file / Milestone L) |
| `make secret-vercel-token-subject` | Pipe subject-bound Vercel token (`SUBJECT=…`) |
| `make deploy` | Deploy runtime image; mount secrets as files |
| `make health` | Stage 2 liveness |
| `make authz-smoke` | Stage 3: unauthenticated `/v1/resolve` → 401 |
| `make logs` | Recent broker Cloud Logging lines |
| `make describe-url` | Print deployed `status.url` |
| `make teardown-docs` | Print teardown commands (does not delete) |
| `make test-providers` | Unit-test deployment-owned exec providers |
| `make validate-remote` | `health` + `authz-smoke` against the deployed URL |

## What this repo builds vs pulls vs mounts

| Component | Source |
|-----------|--------|
| `pade-broker` binary | **Pull** `ghcr.io/after-certainty/pade-broker@sha256:3a17bcd0867e7666870d5e54e42b3cf6a39444d0c5227768fbe3baff0ae353af` |
| GitHub + GA exec providers | **Build** from PADE `v0.2.1` tag during `docker build` |
| Vercel exec provider | **Build** from `providers/vercel` in this repo (deployment-owned) |
| Policy / bindings | **Render** from `config/broker-*.yaml.tmpl` + `.env`, then copy into the overlay |
| App PEM / SA JSON | **Mount** from Secret Manager at deploy |
| Shared Vercel token | **Mount** only if `MOUNT_SHARED_VERCEL_TOKEN=1` |
| Subject Vercel tokens | **Fetched at resolve time** via Cursor WIF (not mounted on Cloud Run) |

## Secret setup

| Secret Manager id | Access |
|-------------------|--------|
| `github-app-private-key` | Mounted for runtime SA at `/run/secrets/github-app/private-key.pem` |
| `google-analytics-sa` | Mounted for runtime SA at `/run/secrets/google-analytics/sa.json` |
| `vercel-token` | Optional shared mount at `/run/secrets/vercel/token` (static-token-file only) |
| `vercel-token-sub-<hash>` | Per-subject; IAM to federated Cursor principal only |

## Capabilities

| Capability | Broker provider | Agent receives | Notes |
|------------|-----------------|----------------|-------|
| `github.repo.read` | `pade-provider-github` (from PADE) | Short-lived `GITHUB_TOKEN` | Reference provider |
| `google-analytics.read` | `pade-provider-google-analytics` (from PADE) | `GA_ACCESS_TOKEN`, `GA_PROPERTY_ID` | Reference provider |
| `vercel.diagnostics` | `pade-provider-vercel` (this repo) | `VERCEL_TOKEN` Material | Opaque id; default fulfillment `subject-secret-wif` |

Agent-side example: [`agent/broker.bindings.example.yaml`](agent/broker.bindings.example.yaml) or `make print-agent-bindings`.

`vercel.diagnostics` does **not** restrict which Vercel operations the token can perform after Material delivery. Downstream Vercel authorization remains authoritative. Prefer the narrowest Vercel scope and expiration Vercel offers; subject-bound WIF improves isolation but does **not** make a broad token read-only.

## Security notes

- Broker must not log identity tokens; provider must not log Vercel tokens
- Secret Manager values must never appear in rendered config under `config/.generated/`
- Capability name ≠ operation allowlist once an opaque vendor token is delivered
- Do not print secret values during validation — use metadata / successful downstream ops as evidence

## Validation

See [`docs/validation.md`](docs/validation.md). Recommended path covers health, authn, GitHub, GA, subject-secret-wif Vercel, ordinary Vercel CLI read diagnostics, and two-subject isolation where practical.

## Provenance

Cloud Run env vars set at deploy: `PADE_VERSION`, `PADE_REF` (from `versions.env`).
GitHub Actions also sets `DEPLOYMENT_GIT_SHA` to the deployment-repo commit and
tags the overlay image with that full SHA (`RUNTIME_IMAGE_TAG`).

## Teardown

```bash
make teardown-docs
```

Prints inspectable delete commands for Cloud Run, secrets (shared + subject-bound), both WIF pools, and service accounts. Does **not** delete by default.

## GitHub Actions CI/CD

See [`docs/github-actions.md`](docs/github-actions.md) for CI, production deploy via **GitHub→GCP** WIF, Environment variables, IAM, and rollback notes. That deploy WIF is separate from **Cursor→GCP** runtime WIF. Overlay build only — no PADE source clone for the broker binary.

## Explicitly deferred

Terraform, custom domains, multi-env, building unreleased PADE commits from this repo.
Narrowing the CI deployer from `roles/run.admin` to `roles/run.developer` after
splitting invoker-IAM setup out of routine deploy (documented TODO in
[`docs/github-actions.md`](docs/github-actions.md)).

Historical Milestone L/M operator notes remain in [`docs/milestone-l-vercel.md`](docs/milestone-l-vercel.md) and [`docs/milestone-m-wif.md`](docs/milestone-m-wif.md); they describe completed work, not future scaffolding.
