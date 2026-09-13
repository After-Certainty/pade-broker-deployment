# Validation checklist for a Cloud Run PADE broker

Public PADE owns Stage 1 (container CI). This deployment repo owns Stages 2–3 as
Make targets. Stages 4+ run from a real workload after you deploy: a Cursor Cloud
Agent **or** a GCE Coder workspace (Google metadata identity).

Use this as a forker’s checklist, not a record of any one deployment.
**Do not print secret values** (OIDC JWTs, Vercel tokens, PEMs, SA JSON) at any stage.
Use metadata and successful downstream operations as evidence.

## Stage 1 — container

Covered by [pade](https://github.com/After-Certainty/pade) CI and the released
`ghcr.io/after-certainty/pade-broker:v0.3.0` image. Optional: `make pull-broker`.

Local overlay checks (this repo):

```bash
make test-providers   # deployment-owned Vercel provider unit tests (fake tokens)
make render-config
make build            # requires Docker; pulls digest-pinned broker
```

- [ ] `make pull-broker` succeeds (digest-pinned image from `versions.env`)
- [ ] `make test-providers` passes
- [ ] `make build` produces an image containing `/providers/pade-provider-vercel`
- [ ] Rendered files under `config/.generated/` contain **no** secret values

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

From a Cursor Cloud Agent (identity socket present). Omitting `broker.identity`
remains valid: PADE v0.3.0 still defaults blank identity to Cursor.

```bash
pade identity --audience "$BROKER_URL"

# Agent bindings: make print-agent-bindings
# endpoint + audience must equal $BROKER_URL and each issuer's audience
```

Expect safe claims only (no raw JWT printed). Then call resolve (via `pade exec`
or HTTP) and confirm allow/deny matches the rendered policy subject
(`CURSOR_OIDC_SUBJECT` / `CURSOR_OIDC_SUBJECTS` in `.env`) under issuer alias
`cursor`. Inspect broker logs (`make logs`) for decisions — not tokens.

- [ ] `pade identity --audience <BROKER_URL>` returns a subject matching `.env`
- [ ] A resolve for that subject is allowed; a different subject is denied

## Stage 4b — real GCE identity (deployed broker)

From the existing `pade-gcp` Coder/GCE workspace (not from GitHub Actions —
runners are not GCE workspace identity).

Use PADE v0.3.0 agent bindings with Google metadata identity:

```yaml
provider: broker
broker:
  endpoint: <real Cloud Run broker URL>
  audience: <same URL>
  identity: gce
```

Request capability `github.repo.read` only (current GCE allowlist). Then run a
child that checks Material without printing it:

```bash
# After pade exec injects Material for the child:
test -n "${GITHUB_TOKEN:-}" && printf 'deployed-gce-broker: success\n'
```

Or print bindings pointed at the predicted/deployed URL:

```bash
make print-agent-bindings-gce
```

This proves:

```text
real GCE metadata JWT
  → deployed Cloud Run broker
  → google issuer selected
  → issuer+subject policy
  → github.repo.read
  → broker-derived Material reaches child
```

Do **not** automate this from GitHub Actions. Do **not** print token contents.

- [ ] GCE resolve for `github.repo.read` succeeds for the allowlisted `GCE_OIDC_SUBJECT`
- [ ] Child sees non-empty `GITHUB_TOKEN` without printing it
- [ ] `vercel.diagnostics` / `google-analytics.read` are **not** assumed for GCE
      (Vercel fulfillment remains Cursor→GCP WIF)

### Architecture (one broker, two issuers)

```text
Cursor Cloud Agent
   ↓ Cursor OIDC
   │
   ├──────────────┐
                  ↓
             one broker
                  ↑
   ├──────────────┘
   │
GCE Coder workspace
   ↓ Google OIDC (GCE metadata)
```

Notes:

- Coder is **not** an identity provider; Google/GCE identity comes from the
  Compute Engine metadata server.
- Broker authorization is **issuer alias + subject**. Adding a trusted issuer
  does not itself grant capabilities.
- GCE currently receives only `github.repo.read` (least privilege). Cursor keeps
  `github.repo.read`, `google-analytics.read`, and `vercel.diagnostics`.

## Stage 5 — Material resolution (GitHub + GA + Vercel subject-secret-wif)

Recommended path uses **subject-secret-wif** for Vercel (template default).

Operator prep (once per project / subject):

```bash
make bootstrap-cursor-wif
# Allowlist subjects in .env (CURSOR_OIDC_SUBJECT or CURSOR_OIDC_SUBJECTS)
GITHUB_APP_PRIVATE_KEY="$(cat github-app.pem)" make secret-github-app
GOOGLE_ANALYTICS_SA_JSON="$(cat ga-sa.json)" make secret-ga-sa
# Per subject (values never printed):
read -rsp "Vercel token: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
SUBJECT='user:…' make secret-vercel-token-subject
unset VERCEL_TOKEN
make render-config
make build && make push && make deploy   # shared vercel-token mount omitted by default
```

From the agent, resolve with **no** App key, SA JSON, Vercel token, or derived
tokens on the VM.

- [ ] GitHub/GA secrets exist and are mounted; subject Vercel secrets exist with
      federated-principal IAM (runtime SA is **not** accessor on subject secrets)
- [ ] Agent resolve for `github.repo.read`, `google-analytics.read`, and
      `vercel.diagnostics` succeeds without local keys

### Alternate: static-token-file (Milestone L)

Only if intentionally using shared authority:

```bash
read -rsp "Vercel token: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
make secret-vercel-token
unset VERCEL_TOKEN
# Bindings must use static-token-file; then:
MOUNT_SHARED_VERCEL_TOKEN=1 make deploy
```

See [`milestone-l-vercel.md`](milestone-l-vercel.md).

## Stage 6 — downstream calls

Use returned authority for the smallest real call:

- **GitHub:** `github.repo.read` → repo metadata for a repo in `GITHUB_REPOSITORIES`
- **Google Analytics:** `google-analytics.read` → property metadata for `GA_PROPERTY_ID`
- **Vercel:** `vercel.diagnostics` → ordinary Vercel CLI **read** diagnostics
  (e.g. `vercel whoami`, project inspect, deployment inspect/logs).
  Do **not** use deploy/delete or other write operations as the acceptance test.

```bash
pade exec --capability vercel.diagnostics -- vercel whoami
```

- [ ] GitHub and GA metadata calls succeed
- [ ] Vercel CLI read diagnostic succeeds with no manually copied credential on the agent

## Stage 7 — two-subject isolation (subject-secret-wif)

Practical when you have two Cursor subjects allowlisted and two subject-bound secrets.

Successful isolation means:

| Actor | Secret | Expected |
|-------|--------|----------|
| Subject A | secret A | resolve / CLI diagnostic **succeeds** |
| Subject B | secret B | resolve / CLI diagnostic **succeeds** |
| Subject A | secret B | **denied** by Google Secret Manager IAM (not by a PADE mapping table) |

Evidence: successful Material for A and B (different downstream identity / whoami if tokens differ),
plus IAM denial when A’s federated principal cannot access B’s secret. **Never** print secret
values; compare whoami / project metadata instead.

Prep:

1. `CURSOR_OIDC_SUBJECTS=subject-a,subject-b` and `make render-config`
2. `SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject` for each subject
3. Bindings already use `fulfillment: subject-secret-wif`
4. Deploy without `MOUNT_SHARED_VERCEL_TOKEN`

See [`milestone-m-wif.md`](milestone-m-wif.md).

## Logging expectations

Broker stderr (Cloud Logging) includes request decisions with subject/capability.
It must not include OIDC JWTs or resolved secrets (PADE behavior).
The Vercel provider must never write the token to stderr.
