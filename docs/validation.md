# Validation checklist for a Cloud Run PADE broker

Public PADE owns Stage 1 (container CI / `make smoke-broker-container`).
This deployment repo owns Stages 2–3 as Make targets. Stages 4–6 run from a
Cursor Cloud Agent after you deploy.

Use this as a forker’s checklist, not a record of any one deployment.

## Stage 1 — container

Covered by [pade](https://github.com/ksteffe/pade) CI and the released
`ghcr.io/ksteffe/pade-broker:v0.1.0` image. Optional: `make pull-broker`.

- [ ] `make pull-broker` succeeds (digest-pinned image from `versions.env`)

## Stage 2 — Cloud Run health

```bash
make health
```

PADE’s liveness path is `GET /healthz` → `200` + `ok`.

**Cloud Run caveat:** Google reserves some URL paths ending in `z` (including
`/healthz`). Public requests to `/healthz` may receive a Google HTML 404 and
never reach the container
([known issues](https://cloud.google.com/run/docs/known-issues)).
`make health` detects that case and confirms broker liveness via
unauthenticated `POST /v1/resolve` → `401` instead.

Local Docker `GET /healthz` continues to work as PADE documents.

- [ ] `make health` reports the broker is live (direct `/healthz` or the 401 fallback)

## Stage 3 — authentication boundary

```bash
make authz-smoke
# POST /v1/resolve without Bearer → HTTP 401
```

Confirms Cloud Run is reachable while the broker still rejects anonymous resolve.

```bash
make validate-remote   # stages 2 + 3
```

- [ ] Unauthenticated `/v1/resolve` returns HTTP 401 (`missing_bearer`)

## Stage 4 — real Cursor identity

From a Cursor Cloud Agent (identity socket present):

```bash
# Build or obtain the pade CLI in the agent environment
./bin/pade identity --audience "$BROKER_URL"

# Agent bindings: make print-agent-bindings
# endpoint + audience must equal $BROKER_URL and policy oidc.audience
```

Expect safe claims only (no raw JWT printed). Then call resolve (via `pade exec`
or HTTP) and confirm allow/deny matches the rendered policy subject
(`CURSOR_OIDC_SUBJECT` in `.env`). Inspect broker logs (`make logs`) for
`decision=`.

- [ ] `pade identity --audience <BROKER_URL>` returns a subject matching `.env`
- [ ] A resolve for that subject is allowed; a different subject is denied

## Stage 5 — derived-token resolution

Broker-side exec providers mint short-lived tokens from durable keys mounted
from Secret Manager:

```bash
GITHUB_APP_PRIVATE_KEY="$(cat github-app.pem)" make secret-github-app
GOOGLE_ANALYTICS_SA_JSON="$(cat ga-sa.json)" make secret-ga-sa
make render-config   # also runs as a dependency of make build
make build && make push && make deploy
```

Non-secret ids come from `.env` (GitHub App id, installation, repos, GA property).
From the agent, resolve with **no** App key, SA JSON, or derived tokens on the VM.

- [ ] Secrets exist in Secret Manager and are mounted on Cloud Run
- [ ] Agent resolve for `github.repo.read` and `google-analytics.read` succeeds without local keys

## Stage 6 — downstream call

Use the returned authority for the smallest real API call:

- **GitHub:** `github.repo.read` → `github-repo-meta` (repo-scoped; not `/user` whoami)
- **Google Analytics:** `google-analytics.read` → `ga-property-meta`

PADE reference scripts live under `examples/demo-project/scripts/` in the public repo.

- [ ] `github-repo-meta` returns metadata for a repo in `GITHUB_REPOSITORIES`
- [ ] `ga-property-meta` returns metadata for `GA_PROPERTY_ID`

## Logging expectations

Broker stderr (Cloud Logging) includes request decisions with subject/capability.
It must not include OIDC JWTs or resolved secrets (PADE behavior).
