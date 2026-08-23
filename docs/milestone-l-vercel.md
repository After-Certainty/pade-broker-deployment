# Milestone L — Shared Vercel token (optional compatibility)

This document is the deployment-side walkthrough for PADE **Milestone L** (complete):
proving that an ordinary Vercel CLI can consume **generic PADE Material** from a
**deployment-owned** exec provider — with **no** Vercel provider, schema, SDK, or
vocabulary added to PADE core.

**Status:** Milestone L is **complete**. The recommended production / dogfood path is now
**Milestone M** `subject-secret-wif` (see [`milestone-m-wif.md`](milestone-m-wif.md)).
Keep this document for:

- the historical L proof
- optional compatibility / local / fallback shared-token deploys
- operators who intentionally want one deployment-owned Vercel token

## Mode comparison

| Mode | Authority model | When to use |
|------|-----------------|-------------|
| **`static-token-file`** (this doc) | One shared deployment-owned token mounted on Cloud Run | Simple dogfood, local bring-up, or explicit compatibility |
| **`subject-secret-wif`** (recommended) | Subject-bound token via Cursor WIF + Secret Manager IAM | Current default bindings; subject-isolated production path |

Shared mount is **opt-in**: set `MOUNT_SHARED_VERCEL_TOKEN=1` when using static-token-file.
A normal subject-secret-wif deploy does **not** need the shared mount.

## Ownership boundary

```text
PADE
    owns generic capability + Material semantics
    (released broker + Consumer; no Vercel-specific code)

pade-broker-deployment (this repo)
    owns concrete Vercel credential fulfillment:
    Secret Manager token, provider binary, broker binding, authorization policy

consumer / application repository
    owns installation and use of the ordinary Vercel CLI
    declares the portable capability via provider: broker
    identifies/links the intended Vercel project with non-secret config
    runs diagnostics with Material injected by `pade exec`
```

Do **not** add a Vercel provider, schema, SDK, MCP integration, or Vercel-specific
vocabulary to the `After-Certainty/pade` repository for this path.

## Intended flow (static-token-file)

```text
cloud DevelopmentSession
        ↓
portable capability request (vercel.diagnostics)
        ↓
released PADE broker (digest-pinned GHCR image)
        ↓
deployment-owned exec provider (/providers/pade-provider-vercel)
        ↓
generic Material { env: { VERCEL_TOKEN: "…" } }
        ↓
ordinary Vercel CLI in the consumer environment
        ↓
read-oriented inspection / logs / diagnostics
```

## Capability id

| Id | Meaning |
|----|---------|
| `vercel.diagnostics` | Opaque, **non-normative**, deployment-chosen capability |

Naming it `vercel.diagnostics` does **not** restrict which Vercel API or CLI operations
the token can perform after Material is delivered. Downstream Vercel token scope remains
authoritative. Prefer the narrowest scope and expiration Vercel offers; this path does
**not** make an inherently broad token read-only.

## Broker / deployment responsibilities (static-token-file)

1. Store a Vercel access token in Secret Manager (`vercel-token`).
2. Mount it at `/run/secrets/vercel/token` on Cloud Run by setting
   `MOUNT_SHARED_VERCEL_TOKEN=1` for `make deploy`.
3. Ship `/providers/pade-provider-vercel` in the runtime overlay.
4. Bind `vercel.diagnostics` → `provider: exec` with server-owned config
   (`tokenFile`, `tokenEnv`) — never put the token in rendered YAML or `.env`.
   (Template default is `subject-secret-wif`; for this mode replace with static-token-file config.)
5. Allow the capability for the configured Cursor OIDC subject in broker policy.
6. Deliver Material only through the released broker’s resolve path.

The provider:

- does **not** call the Vercel API or install/run the Vercel CLI
- does **not** invent expiry when opaque token lifetime is unknown
- returns static Material from the mounted file
- must never write the token to stderr / logs

## Consumer / application responsibilities

1. Install the ordinary Vercel CLI in the agent / app environment.
2. Point agent bindings at the Cloud Run broker (`make print-agent-bindings`).
3. Use non-secret project identifiers as needed by the CLI (project name/id, team slug).
4. Run diagnostics via PADE:

```bash
pade exec --capability vercel.diagnostics -- vercel whoami
pade exec --capability vercel.diagnostics -- vercel project ls
```

Use read-oriented diagnostics only for acceptance. Do **not** use deploy/delete
or other write operations as the acceptance test.

## Secret setup

```bash
read -rsp "Vercel token: " VERCEL_TOKEN && echo && export VERCEL_TOKEN
make secret-vercel-token
unset VERCEL_TOKEN
```

Metadata-only verification (never print the secret value):

```bash
gcloud secrets describe vercel-token --project="$PROJECT_ID"
gcloud secrets versions list vercel-token --project="$PROJECT_ID" --filter='state=ENABLED' --limit=1
```

Do **not** use `gcloud secrets versions access` as a validation step.

## Deploy (static-token-file)

1. In bindings, use static-token-file config (see comments in
   [`config/broker-bindings.yaml.tmpl`](../config/broker-bindings.yaml.tmpl)).
2. `MOUNT_SHARED_VERCEL_TOKEN=1 make deploy`
3. `make validate-remote`
4. From a Cursor Cloud Agent: resolve `vercel.diagnostics` and run ordinary CLI diagnostics.

## Security model (shared token)

| Layer | What it does |
|-------|----------------|
| Broker OIDC policy | Who may request `vercel.diagnostics` |
| Exec provider | Turns mounted file into Material env |
| Consumer `pade exec` | Injects Material into a scoped child process |
| Vercel token scope | What the CLI/API can actually do |

PADE does **not** mediate individual Vercel operations after Material delivery.
All allowlisted subjects share the same organizational token on this path.

## What this is / is not

| This is | This is not |
|---------|-------------|
| Completed Milestone L external CLI dogfood | The recommended subject-isolated production default |
| Deployment-specific wiring | First-class PADE Vercel support |
| Static Material from a shared Secret Manager mount | Per-subject Vercel credentials |
| Ordinary Vercel CLI in the consumer | Vercel CLI or MCP inside the broker image |

For subject-bound authority, use [`milestone-m-wif.md`](milestone-m-wif.md).
