# Milestone M — Subject-bound authority (Google WIF experiment)

This document is the deployment-side plan and analysis for PADE **Milestone M**,
as defined in the upstream
[PADE ROADMAP](https://github.com/After-Certainty/pade/blob/main/ROADMAP.md)
(*Milestone M — Subject-bound authority (Google WIF experiment)*).

Milestone L (shared organizational Vercel Material) is **complete** in this repo
and remains the default production path. See
[`milestone-l-vercel.md`](milestone-l-vercel.md).

## Milestone L + CI/CD verification (precondition)

| Area | Status | Evidence |
|------|--------|----------|
| Deployment-owned Vercel exec provider | Done | [`providers/vercel/`](../providers/vercel/) |
| Secret Manager `vercel-token` + Cloud Run mount | Done | `make secret-vercel-token`, [`scripts/deploy.sh`](../scripts/deploy.sh) |
| Binding + policy for `vercel.diagnostics` | Done | [`config/broker-bindings.yaml.tmpl`](../config/broker-bindings.yaml.tmpl), [`config/broker-policy.yaml.tmpl`](../config/broker-policy.yaml.tmpl) |
| Provider unit tests | Done | `make test-providers` |
| Docs / validation Stage 6 | Done | this tree + [`validation.md`](validation.md) |
| CI (credential-free) | Done | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |
| Production deploy (OIDC → WIF → deployer SA) | Done | [`.github/workflows/deploy-production.yml`](../.github/workflows/deploy-production.yml), [`github-actions.md`](github-actions.md) |

Upstream ROADMAP already marks Milestone L **DONE**. Live Stages 4–6 remain
operator-run against a real Cursor agent; that does not leave L incomplete
in-repo. Production CI/CD is sound for a template repo (SHA-tagged overlays,
Environment `production`, no long-lived SA keys).

## Ownership boundary (ROADMAP)

```text
PADE
    owns generic capability + Material semantics
    may receive only the smallest generic fix if M proves a seam gap

pade-broker-deployment (this repo)
    owns Cursor→GCP WIF pool, per-subject Secret Manager IAM,
    deployment-owned provider fulfillment, broker policy/bindings

consumer / application repository
    owns ordinary Vercel CLI usage under pade exec
    same portable capability id (vercel.diagnostics)
```

Do **not** add PADE-owned `userSecrets`, `subjectBindings`, or a subject→secret
table to `After-Certainty/pade`. Do **not** make Google WIF or Secret Manager
part of the PADE protocol.

## Intended flow

```text
authenticated Cursor subject A
        ↓
PADE broker (authn/authz)
        ↓
deployment-owned exec provider
        ↓
Google STS token exchange (Cursor OIDC → federated principal A)
        ↓
Secret Manager IAM (principal A only)
        ↓
Vercel token Material for A
```

Subject B follows the same portable capability and receives different Material.
Shared organizational authority (Milestone L static mount) remains a valid model.

## Does PADE need changes?

**Shipped in `pade-broker` v0.1.1** (design question **#17** / ROADMAP acceptance
“No”). Pin this repo to:

| Field | Value |
|-------|--------|
| Image | `ghcr.io/after-certainty/pade-broker:v0.1.1` |
| Digest | `sha256:6c03d75475e23be9aef7aed867e746ae59cb3c16629e6d264465794fcab175bf` |
| Source | `7cecd5e88f74ed47af74a6d09289c7bd1aeac566` (includes identity forward) |

### Why identity context was required

Without forwarding, the broker-side exec adapter sent only
`{capability, operation, config}`. Provider environment is still a filtered copy
of the Cloud Run **runtime service account** — the same Google principal for
every Cursor subject — so Secret Manager IAM cannot isolate A vs B.

True downstream IAM isolation needs the provider to call Google STS **with the
Cursor OIDC token**. As of v0.1.1, after successful verify + authorize the broker
attaches broker-verified identity to trusted `provider: exec` stdin (exact
presented bearer JWT). See upstream `docs/provider-contract.md`.

| Approach without broker identity context | Result |
|------------------------------------------|--------|
| Runtime SA ADC + secret-name template | Needs subject string; IAM does **not** isolate by Cursor subject |
| Mount all per-subject secrets on Cloud Run | Still needs subject; weakens IAM story |
| PADE-owned subject→secret map | Explicitly forbidden by ROADMAP |
| Full M WIF as diagrammed | Needs `identity.idToken` on exec Request (now available on v0.1.1+) |

Vendor WIF/Secret Manager wiring stays in this repo. The `subject-secret-wif`
mode in [`providers/vercel/`](../providers/vercel/) **fails closed** when
`identity.idToken` is absent (older brokers or failed verify).

## What this repo scaffolds now

| Piece | Make / path | Notes |
|-------|-------------|-------|
| Cursor → GCP WIF pool | `make bootstrap-cursor-wif` | Separate from GitHub Actions deployer WIF |
| Per-subject Vercel secrets | `make secret-vercel-token-subject SUBJECT=…` | IAM to **federated principal**, not runtime SA |
| Provider WIF mode | `fulfillment: subject-secret-wif` in exec config | Stdlib STS + Secret Manager REST |
| Multi-subject policy | `CURSOR_OIDC_SUBJECTS` (comma-separated) | Same capability for A and B |
| Shared L path | unchanged default | `fulfillment` omitted / `static-token-file` |

### Secret id convention

Subject-bound secrets use a deterministic Secret Manager id (SM id charset):

```text
vercel-token-sub-<first 16 hex chars of sha256(utf8(subject))>
```

Populate and provider code share this convention. Isolation is enforced by
Secret Manager IAM on the federated principal — not by a PADE mapping table.

### M binding (active in template)

[`config/broker-bindings.yaml.tmpl`](../config/broker-bindings.yaml.tmpl) uses
`fulfillment: subject-secret-wif` for `vercel.diagnostics`. `make render-config`
fills `projectNumber` / WIF ids / secret prefix from the project + `versions.env`:

```yaml
vercel.diagnostics:
  provider: exec
  exec:
    command: ["/providers/pade-provider-vercel"]
    config:
      fulfillment: subject-secret-wif
      tokenEnv: VERCEL_TOKEN
      projectNumber: "${PROJECT_NUMBER}"
      poolId: "${CURSOR_WIF_POOL_ID}"
      providerId: "${CURSOR_WIF_PROVIDER_ID}"
      secretIdPrefix: "${VERCEL_SUBJECT_SECRET_PREFIX}"
```

Exec Request shape on broker v0.1.1+ (when verify succeeds):

```json
{
  "capability": "vercel.diagnostics",
  "operation": "resolve",
  "config": { },
  "identity": {
    "subject": "user:…",
    "idToken": "<Cursor OIDC JWT>"
  }
}
```

## Operator checklist

1. Deploy against broker **v0.1.1+** (digest-pinned in [`versions.env`](../versions.env)).
2. `make bootstrap-cursor-wif` (once per project; admin). Must set
   `--allowed-audiences` to the broker URL (Cursor token `aud`). Re-run after
   the broker URL changes.
3. Allowlist subjects: set `CURSOR_OIDC_SUBJECTS=subject-a,subject-b` in `.env`
   (or keep single `CURSOR_OIDC_SUBJECT`).
4. For each subject: `SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject`
   (history-safe `read -rsp` recommended).
5. `make render-config && make build && make push && make deploy` (bindings already
   use `subject-secret-wif`; master pipeline does this on merge).
6. Acceptance: subject A and B resolve the **same** capability to **different**
   Vercel Material; cross-subject Secret Manager access denied by IAM.

### Troubleshooting broker 502 on `vercel.diagnostics`

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| STS exchange fails / 502 after M flip | WIF provider missing broker URL in allowed audiences | Re-run `make bootstrap-cursor-wif` (sets `--allowed-audiences=${BROKER_URL}`) |
| Secret Manager access denied | Federated principal IAM missing on subject secret | Re-run `make secret-vercel-token-subject` for that subject |
| Identity missing in provider | Broker &lt; v0.1.1 | Pin/deploy broker v0.1.1+ |

## What this is / is not

| This is | This is not |
|---------|-------------|
| Milestone M experiment scaffolding | Completed live A/B E2E (operator still required) |
| Deployment + IAM composition | PADE protocol / `userSecrets` |
| Consumer of ROADMAP #17 (broker v0.1.1) | A Vercel-specific PADE feature |
| Compatible with shared L authority | A rewrite of every capability as user-specific |
