# Validation checklist for a Cloud Run PADE broker

Public PADE owns Stage 1 (container CI / `make smoke-broker-container`).
This deployment repo owns Stages 2–3 as Make targets. Stages 4–6 run from a
Cursor Cloud Agent after you deploy.

Use this as a forker’s checklist, not a record of any one deployment.

## Stage 1 — container

Covered by [pade](https://github.com/After-Certainty/pade) CI and the released
`ghcr.io/after-certainty/pade-broker:v0.1.1` image. Optional: `make pull-broker`.

Local overlay checks (this repo):

```bash
make test-providers   # deployment-owned Vercel provider unit tests (fake tokens)
make render-config
make build            # requires Docker; pulls digest-pinned broker
```

- [ ] `make pull-broker` succeeds (digest-pinned image from `versions.env`)
- [ ] `make test-providers` passes
- [ ] `make build` produces an image containing `/providers/pade-provider-vercel`

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

## Stage 5 — Material resolution

Broker-side exec providers fulfill capabilities from durable keys mounted
from Secret Manager:

```bash
GITHUB_APP_PRIVATE_KEY="$(cat github-app.pem)" make secret-github-app
GOOGLE_ANALYTICS_SA_JSON="$(cat ga-sa.json)" make secret-ga-sa
read -rsp "Vercel token: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
make secret-vercel-token
unset VERCEL_TOKEN
make render-config   # also runs as a dependency of make build
make build && make push && make deploy
```

Non-secret ids come from `.env` (GitHub App id, installation, repos, GA property).
From the agent, resolve with **no** App key, SA JSON, Vercel token, or derived
tokens on the VM.

- [ ] Secrets exist in Secret Manager and are mounted on Cloud Run
- [ ] Agent resolve for `github.repo.read`, `google-analytics.read`, and
      `vercel.diagnostics` succeeds without local keys

## Stage 6 — downstream call

Use the returned authority for the smallest real call:

- **GitHub:** `github.repo.read` → `github-repo-meta` (repo-scoped; not `/user` whoami)
- **Google Analytics:** `google-analytics.read` → `ga-property-meta`
- **Vercel (Milestone L):** `vercel.diagnostics` → ordinary Vercel CLI read/diagnostics
  (e.g. `vercel whoami`, `vercel project inspect`, `vercel inspect`, `vercel logs`).
  See [`milestone-l-vercel.md`](milestone-l-vercel.md). Do **not** use deploy/delete
  or other write operations as the acceptance test.

PADE reference scripts for GitHub/GA live under `examples/demo-project/scripts/`
in the public [pade](https://github.com/After-Certainty/pade) repo.

- [ ] `github-repo-meta` returns metadata for a repo in `GITHUB_REPOSITORIES`
- [ ] `ga-property-meta` returns metadata for `GA_PROPERTY_ID`
- [ ] `pade exec --capability vercel.diagnostics -- vercel whoami` (or inspect/logs)
      succeeds with no manually copied Vercel credential in the agent

## Stage 7 — Milestone M subject-bound Material (operator E2E)

See [`milestone-m-wif.md`](milestone-m-wif.md). PADE **v0.1.1** forwards
broker-verified `identity` to trusted exec providers. Operator prep:

1. Pin/deploy this repo against `ghcr.io/after-certainty/pade-broker:v0.1.1`
2. `make bootstrap-cursor-wif`
3. Allowlist A/B subjects via `CURSOR_OIDC_SUBJECTS` and `make render-config`
4. `SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject` per subject
5. Flip `vercel.diagnostics` to `fulfillment: subject-secret-wif` and re-deploy

Acceptance: same `vercel.diagnostics` capability → different Material via WIF +
Secret Manager IAM. Keep production on Milestone L static mounts until that flip.

## Logging expectations

Broker stderr (Cloud Logging) includes request decisions with subject/capability.
It must not include OIDC JWTs or resolved secrets (PADE behavior).
The Vercel provider must never write the token to stderr.
