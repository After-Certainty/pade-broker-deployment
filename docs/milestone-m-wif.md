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

**Yes — for full end-to-end WIF isolation against released `pade-broker` v0.1.0.**

### Why the current exec contract is insufficient

The broker-side exec adapter sends only:

```json
{ "capability": "…", "operation": "resolve", "config": { } }
```

No subject, no ID token. Provider environment is a filtered copy of the Cloud Run
**runtime service account** ambient environment — the same Google principal for
every Cursor subject.

True downstream IAM isolation requires the provider to call Google STS **with
the Cursor OIDC token** so Secret Manager sees federated principal A vs B. The
broker already verified that JWT at `/v1/resolve`, but does **not** forward it
(or any verified identity context) to exec providers.

| Approach without broker identity context | Result |
|------------------------------------------|--------|
| Runtime SA ADC + secret-name template | Needs subject string; IAM does **not** isolate by Cursor subject |
| Mount all per-subject secrets on Cloud Run | Still needs subject; weakens IAM story |
| PADE-owned subject→secret map | Explicitly forbidden by ROADMAP |
| Full M WIF as diagrammed | **Blocked** until trusted providers receive broker-verified identity (at minimum the presented ID token) |

### Acceptance branch (ROADMAP)

This maps to ROADMAP acceptance **“No”**: a **generic** deficiency — trusted
external providers need carefully scoped access to **broker-verified workload
identity** (design question **#17**). Vendor WIF/Secret Manager wiring stays in
this repo. Only the identity-context seam should return to PADE.

Until that PADE change lands, the `subject-secret-wif` fulfillment mode in
[`providers/vercel/`](../providers/vercel/) **fails closed** when identity
context is absent (expected on broker v0.1.0).

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

### Example M binding (not the default deploy)

Keep Milestone L as the deployed default. When PADE can supply identity context,
switch `vercel.diagnostics` exec config to something like:

```yaml
vercel.diagnostics:
  provider: exec
  exec:
    command: ["/providers/pade-provider-vercel"]
    config:
      fulfillment: subject-secret-wif
      tokenEnv: VERCEL_TOKEN
      projectNumber: "123456789012"
      poolId: pade-broker-cursor
      providerId: cursor
      secretIdPrefix: vercel-token-sub
```

Expected forward-compatible exec Request shape (PADE change):

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

1. `make bootstrap-cursor-wif` (once per project; admin).
2. Allowlist subjects: set `CURSOR_OIDC_SUBJECTS=subject-a,subject-b` in `.env`
   (or keep single `CURSOR_OIDC_SUBJECT`).
3. For each subject: `SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject`
   (history-safe `read -rsp` recommended).
4. Keep production on Milestone L until PADE ships identity context; then flip
   bindings to `subject-secret-wif` and re-deploy.
5. Acceptance: subject A and B resolve the **same** capability to **different**
   Vercel Material; cross-subject Secret Manager access denied by IAM.

## What this is / is not

| This is | This is not |
|---------|-------------|
| Milestone M experiment scaffolding | Completed live A/B E2E on broker v0.1.0 |
| Deployment + IAM composition | PADE protocol / `userSecrets` |
| Evidence for ROADMAP question #17 | A Vercel-specific PADE feature |
| Compatible with shared L authority | A rewrite of every capability as user-specific |
