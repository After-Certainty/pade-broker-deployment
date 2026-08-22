# Milestone L — External CLI authority dogfood (Vercel)

This document is the deployment-side walkthrough for PADE **Milestone L**.
Vercel is a concrete external dogfood case, **not** first-class PADE support.

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
vocabulary to the `After-Certainty/pade` repository for this milestone.

## Intended flow

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
| `vercel.diagnostics` | Opaque, **non-normative**, deployment-chosen capability for Milestone L |

This is **not** a standardized PADE capability. Naming it `vercel.diagnostics`
does **not** restrict which Vercel API or CLI operations the token can perform
after Material is delivered. Downstream Vercel token scope remains authoritative.

## Broker / deployment responsibilities

1. Store a Vercel access token in Secret Manager (`vercel-token`).
2. Mount it at `/run/secrets/vercel/token` on Cloud Run.
3. Ship `/providers/pade-provider-vercel` in the runtime overlay.
4. Bind `vercel.diagnostics` → `provider: exec` with server-owned config
   (`tokenFile`, `tokenEnv`) — never put the token in rendered YAML or `.env`.
5. Allow the capability for the configured Cursor OIDC subject in broker policy.
6. Deliver Material only through the released broker’s `/v1/resolve` path.

The provider:

- does **not** call the Vercel API or install/run the Vercel CLI
- does **not** invent `expiresAt` (opaque token expiry is not known)
- returns static Material from the mounted file

## Consumer / application responsibilities

1. Install the ordinary Vercel CLI in the agent / app environment.
2. Point agent bindings at the Cloud Run broker (`make print-agent-bindings`).
3. Use non-secret project identifiers as needed by the CLI (project name/id,
   team slug) — not secrets.
4. Run diagnostics via PADE:

```bash
pade exec --capability vercel.diagnostics -- vercel whoami
pade exec --capability vercel.diagnostics -- vercel project inspect <project>
pade exec --capability vercel.diagnostics -- vercel inspect <deployment-url-or-id>
pade exec --capability vercel.diagnostics -- vercel logs <deployment-url-or-id>
```

Use current Vercel CLI syntax for your installed CLI version. Do **not** use
`vercel deploy`, project deletion, env/domain mutation, or other write operations
as the Milestone L acceptance test.

## Secret setup (interactive)

Create a token in the Vercel UI:

1. Open [Account Tokens](https://vercel.com/account/tokens) (Account → Settings → Tokens).
2. Name it clearly (e.g. `pade-milestone-l-diagnostics`).
3. Prefer the narrowest scope Vercel currently offers that still allows diagnostics:
   **Project** scope for the target project (Vercel also offers Team and Full Account).
4. Choose a **finite / short practical expiration** (not indefinite).
5. Copy the token once at creation (it is not shown again).

Important vendor caveats:

- Project scope limits blast radius to one project, but Vercel does **not**
  currently offer a read-only token class in the access-token UI/docs. A
  project-scoped token can still mutate that project.
- If you must use Team or Full Account scope, treat the credential as highly
  sensitive and keep expiration short.

Populate Secret Manager **without** putting the token in shell history or chat:

```bash
read -rsp "Vercel token: " VERCEL_TOKEN
echo
export VERCEL_TOKEN
make secret-vercel-token
unset VERCEL_TOKEN
```

Metadata-only verification (never print the secret value):

```bash
# Secret exists
gcloud secrets describe vercel-token --project="$PROJECT_ID"

# Has an enabled version (no value shown)
gcloud secrets versions list vercel-token --project="$PROJECT_ID" --filter='state=ENABLED' --limit=1

# Runtime SA can access
gcloud secrets get-iam-policy vercel-token --project="$PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.role:roles/secretmanager.secretAccessor AND bindings.members:serviceAccount:pade-broker-runtime@"
```

Do **not** use `gcloud secrets versions access` as a validation step.

## Deploy and validate

```bash
make render-config
make build
make push
make deploy
make validate-remote   # health + unauthenticated resolve → 401
make print-agent-bindings
```

Then from a Cursor Cloud Agent with the released PADE Consumer and ordinary
Vercel CLI installed, run a read-oriented diagnostic under `pade exec` as above.
A fresh DevelopmentSession must **not** contain a manually copied Vercel credential.

## Security model (Milestone L)

| Layer | What it does |
|-------|----------------|
| Broker OIDC policy | Who may request `vercel.diagnostics` |
| Exec provider | Turns mounted file into Material.env |
| Consumer `pade exec` | Injects Material into a scoped child process |
| Vercel token scope | What the CLI/API can actually do |

PADE does **not** mediate individual Vercel operations after Material delivery.
The agent receives the token for the lifetime of that child execution.

## What this is / is not

| This is | This is not |
|---------|-------------|
| Milestone L external CLI dogfood | Completed Milestone M live A/B E2E |
| Deployment-specific wiring | First-class PADE Vercel support |
| Static Material from Secret Manager | Per-user Vercel credentials / `userSecrets` |
| Ordinary Vercel CLI in the consumer | Vercel CLI or MCP inside the broker image |

Subject-specific Vercel credentials, Google WIF, and Secret Manager IAM keyed by
subject are scaffolded under Milestone M — see [`milestone-m-wif.md`](milestone-m-wif.md).
Keep this Milestone L path as the default shared-authority deploy until you
intentionally flip bindings to `subject-secret-wif` (requires broker **v0.1.1+**
identity forwarding).
