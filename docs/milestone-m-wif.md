# Milestone M — Subject-bound Vercel authority (recommended)

This document is the deployment-side operator guide for **completed** Milestone M:
subject-bound Vercel Material via Cursor OIDC → Google WIF → Secret Manager IAM.

Upstream status: **DONE** in the [PADE ROADMAP](https://github.com/After-Certainty/pade/blob/main/ROADMAP.md)
(*Milestone M — Subject-bound authority*). Broker **v0.1.1** ships the identity-forwarding
seam; this repo’s bindings default to `fulfillment: subject-secret-wif`.

Milestone L (shared organizational Vercel token) remains available as an **optional**
compatibility path — see [`milestone-l-vercel.md`](milestone-l-vercel.md). It is **not**
the recommended default.

## Ownership boundary

```text
PADE
    owns generic capability + Material semantics
    ships broker-verified identity context for trusted exec (v0.1.1)

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

## Why v0.1.1 identity context was required

Without forwarding, the broker-side exec adapter sent only capability / operation / config.
Provider environment is still a filtered copy of the Cloud Run **runtime service account** —
the same Google principal for every Cursor subject — so Secret Manager IAM cannot isolate A vs B.

True downstream IAM isolation needs the provider to call Google STS **with the Cursor OIDC token**.
As of v0.1.1, after successful verify + authorize the broker attaches broker-verified identity to
trusted `provider: exec` stdin (exact presented bearer JWT + verified subject). See upstream
`docs/provider-contract.md`.

This identity object is:

- broker-side only, after verification / authorization
- **not** portable Intent
- **not** consumer configuration
- **not** a PADE user database
- **not** vendor identity semantics inside PADE

| Approach without broker identity context | Result |
|------------------------------------------|--------|
| Runtime SA ADC + secret-name template | Needs subject string; IAM does **not** isolate by Cursor subject |
| Mount all per-subject secrets on Cloud Run | Still needs subject; weakens IAM story |
| PADE-owned subject→secret map | Explicitly forbidden by ROADMAP |
| Full M WIF as diagrammed | Needs `identity.idToken` on exec Request (available on v0.1.1+) |

The `subject-secret-wif` mode in [`providers/vercel/`](../providers/vercel/) **fails closed**
when `identity.idToken` is absent (older brokers or failed verify). When both `identity.subject`
and `identity.idToken` are present, the provider requires `subject` to match the token `sub`
before federation.

## Pin

| Field | Value |
|-------|--------|
| Image | `ghcr.io/after-certainty/pade-broker:v0.1.1` |
| Digest | `sha256:6c03d75475e23be9aef7aed867e746ae59cb3c16629e6d264465794fcab175bf` |
| Source | `7cecd5e88f74ed47af74a6d09289c7bd1aeac566` |

## What this repo provides

| Piece | Make / path | Notes |
|-------|-------------|-------|
| Cursor → GCP WIF pool | `make bootstrap-cursor-wif` | **Separate** from GitHub Actions deployer WIF |
| Per-subject Vercel secrets | `make secret-vercel-token-subject SUBJECT=…` | IAM to **federated principal**, not runtime SA |
| Provider WIF mode | `fulfillment: subject-secret-wif` in exec config | Stdlib STS + Secret Manager REST |
| Multi-subject policy | `CURSOR_OIDC_SUBJECTS` (comma-separated) | Same capability for A and B |
| Shared L path | opt-in | `static-token-file` + `MOUNT_SHARED_VERCEL_TOKEN=1` |

### Secret id convention (naming, not authorization)

Subject-bound secrets use a deterministic Secret Manager id:

```text
vercel-token-sub-<first 16 hex chars of sha256(utf8(subject))>
```

Populate scripts and provider code share this convention. **Hashing a subject into a secret
name is not authorization.** Isolation is enforced by Secret Manager IAM on the federated
principal — not by a PADE mapping table and not by the hash itself.

### Binding (active in template)

[`config/broker-bindings.yaml.tmpl`](../config/broker-bindings.yaml.tmpl) uses
`fulfillment: subject-secret-wif` for `vercel.diagnostics`. `make render-config`
fills project number / WIF ids / secret prefix from the project + `versions.env`.

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
2. `make bootstrap-cursor-wif` (once per project; admin). Must set allowed audiences to the
   broker URL (Cursor token `aud`). Re-run after the broker URL changes.
3. Allowlist subjects: `CURSOR_OIDC_SUBJECTS=subject-a,subject-b` in `.env`
   (or keep single `CURSOR_OIDC_SUBJECT`).
4. For each subject: `SUBJECT=… VERCEL_TOKEN=… make secret-vercel-token-subject`
   (history-safe `read -rsp` recommended). Never print the token.
5. `make render-config && make build && make push && make deploy` (bindings already use
   `subject-secret-wif`; shared Vercel mount is omitted unless `MOUNT_SHARED_VERCEL_TOKEN=1`).
6. Acceptance: subject A and B resolve the **same** capability to **different** Vercel Material;
   cross-subject Secret Manager access denied by IAM.

### Optional: drop the shared Milestone L secret

With `subject-secret-wif` active, deploys omit `/run/secrets/vercel/token` unless
`MOUNT_SHARED_VERCEL_TOKEN=1`. After a deploy without that mount you may delete the shared secret:

```bash
gcloud secrets delete vercel-token --project="$PROJECT_ID"
```

Subject-bound secrets (`vercel-token-sub-…`) are unchanged.

### Troubleshooting broker failures on `vercel.diagnostics`

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| STS exchange fails / broker error after WIF deploy | WIF provider missing broker URL in allowed audiences | Re-run `make bootstrap-cursor-wif` |
| Secret Manager access denied | Federated principal IAM missing on subject secret | Re-run `make secret-vercel-token-subject` for that subject |
| Identity missing in provider | Broker &lt; v0.1.1 | Pin/deploy broker v0.1.1+ |

## Two WIF paths reminder

| Pool | Make target | Trust boundary | Purpose |
|------|-------------|----------------|---------|
| `pade-broker-github` | `make bootstrap-github-wif` | GitHub Actions OIDC → deployer SA | Deploy Cloud Run / push images |
| `pade-broker-cursor` | `make bootstrap-cursor-wif` | Cursor OIDC → federated subject | Runtime subject-bound Secret Manager access |

These are **not** one shared WIF mechanism.

## What this is / is not

| This is | This is not |
|---------|-------------|
| Completed Milestone M recommended path | Unfinished scaffolding or an optional “flip” from production L |
| Deployment + IAM composition | PADE protocol / `userSecrets` |
| Consumer of broker v0.1.1 identity forwarding | A Vercel-specific PADE feature |
| Compatible with optional shared L authority | A rewrite of every capability as user-specific |

Milestones N (full Cloud Agent acceptance) and O (no further protocol work) are also **complete**
upstream; see the PADE ROADMAP rather than duplicating it here.
