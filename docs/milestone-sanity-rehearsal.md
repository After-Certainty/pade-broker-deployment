# Sanity rehearsal capability (deployment-owned)

Deployment-side guide for **`sanity.rehearsal.write`**: subject-bound Sanity API
token Material via Cursor OIDC → Google WIF → Secret Manager IAM.

This is **deployment-specific** Sanity support in `pade-broker-deployment`. It is
**not** PADE-core Sanity support. Do not add Sanity providers, schemas, SDKs, or
vocabulary to `After-Certainty/pade`.

## Ownership boundary

```text
PADE
    owns generic capability + Material semantics
    ships broker-verified identity context for trusted exec

pade-broker-deployment (this repo)
    owns Cursor→GCP WIF pool, per-subject Secret Manager IAM,
    deployment-owned Sanity credential fulfillment, broker policy/bindings,
    capability-specific Cursor subject allowlist (SANITY_CURSOR_OIDC_SUBJECTS)

consumer / application repository
    owns Sanity project ID + dataset configuration
    owns ordinary Sanity CLI / API / library use under pade exec
```

Do **not** add a PADE-owned user→secret table. Do **not** put vendor credentials
on the Cursor VM. Do **not** encode `SANITY_PROJECT_ID` / `SANITY_DATASET` into
broker Material — those are non-secret consumer configuration.

## Intended flow

```text
fresh Cursor Cloud Agent
        ↓ Cursor OIDC
PADE broker (verify + authorize)
        ↓ sanity.rehearsal.write (allowlisted subject only)
deployment-owned exec provider (providers/sanity)
        ↓ broker-forwarded identity.idToken
Google STS (Cursor OIDC → federated principal)
        ↓
Secret Manager IAM (federated principal only)
        ↓
SANITY_API_TOKEN Material
```

The broker/provider delivers the credential only. The consumer chooses the
configured rehearsal project/dataset.

## Capability semantics

| Piece | Meaning |
|-------|---------|
| `sanity.rehearsal.write` | Opaque, **non-normative**, deployment-chosen capability id |
| Material | `{ "env": { "SANITY_API_TOKEN": "…" } }` |
| Authorization boundary | Broker policy allowlist **and** Secret Manager IAM on the federated Cursor principal |
| Operation ACL | **Not** the capability name — the downstream Sanity credential decides what the caller can do |

The rehearsal credential must be dedicated to a **disposable rehearsal**
environment with only the minimum provider-side authority needed. Rehearsal
credentials must **never** be promoted to production. Production Sanity must
later receive a separate credential/capability.

## Policy allowlist

Every subject in `CURSOR_OIDC_SUBJECT(S)` receives the common Cursor capabilities
(`github.repo.read`, `google-analytics.read`, `vercel.diagnostics`).

`sanity.rehearsal.write` is **not** granted automatically. Set:

```bash
# Optional; defaults to empty (no Sanity grants). Identifier, not a secret.
SANITY_CURSOR_OIDC_SUBJECTS=user:SUBJECT_A
```

Semantics:

- Comma-separated Cursor OIDC subjects
- Each value must also appear in `CURSOR_OIDC_SUBJECT` / `CURSOR_OIDC_SUBJECTS`
- Unknown / non-subset values fail `make render-config` clearly (fail closed)
- GCE subjects never receive Sanity

## Secret id convention (naming, not authorization)

```text
sanity-token-sub-<first 16 hex chars of sha256(utf8(subject))>
```

Prefix default: `SANITY_SUBJECT_SECRET_PREFIX=sanity-token-sub` in
[`versions.env`](../versions.env). Populate scripts and provider code share this
convention. **Hashing a subject into a secret name is not authorization.**
Isolation is Secret Manager IAM on the federated principal.

## Binding

[`config/broker-bindings.yaml.tmpl`](../config/broker-bindings.yaml.tmpl) binds
`sanity.rehearsal.write` to `/providers/pade-provider-sanity` with
`fulfillment: subject-secret-wif` and the same Cursor WIF inputs as Vercel.
No tokens, project IDs, dataset names, or Cursor subjects appear in the template.

The provider **fails closed** when `identity.idToken` is absent. When both
`identity.subject` and `identity.idToken` are present, subject must match the
token `sub` before federation. The Cloud Run runtime SA is **not** an accessor
on subject-bound Sanity secrets.

## Operator checklist (live deployment — next session)

Do **not** commit real subjects, tokens, or account/project IDs to this public repo.

1. Obtain the fresh Cursor OIDC subject (`pade identity --audience <broker-url>`).
2. Add it privately to `CURSOR_OIDC_SUBJECT` / `CURSOR_OIDC_SUBJECTS`.
3. Add it privately to `SANITY_CURSOR_OIDC_SUBJECTS`.
4. Ensure `make bootstrap-cursor-wif` has been run for the broker audience.
5. Create the disposable rehearsal Sanity project (consumer / operator side).
6. Create a dedicated rehearsal-only Sanity write credential (minimum scope).
7. Populate the subject-bound secret (history-safe):

   ```bash
   read -rsp "Sanity API token: " SANITY_API_TOKEN; echo; export SANITY_API_TOKEN
   SUBJECT='user:…' make secret-sanity-token-subject
   unset SANITY_API_TOKEN
   ```

8. Provision/verify the subject’s Vercel authority for the intended project via
   the existing Vercel flow (`make secret-vercel-token-subject`). Acceptance is
   read-oriented diagnostics only.
9. `make render-config && make build && make push && make deploy`.
10. Configure a fresh Cursor agent with released PADE + broker bindings
    (`make print-agent-bindings`). Agent YAML has endpoint/audience/capability
    declarations only — no Sanity token or project ID required in the binding.
11. Run acceptance in [`validation.md`](validation.md) (Sanity + Vercel) without
    copying provider secrets onto the agent.

## Coexistence with Vercel (one token per subject)

Existing `vercel.diagnostics` uses one Secret Manager secret per Cursor subject
(`vercel-token-sub-…`). This Sanity work does **not** change that path.

If the Cursor subject already has a useful Vercel credential for other projects,
do **not** silently overwrite it. The operator must either:

- ensure that subject’s existing Vercel token can also see the intended project, or
- stop and introduce a **second** deployment-owned Vercel authority/binding with a
  distinct `secretIdPrefix` (smallest expansion) — not implemented in this pass.

`vercel.diagnostics` does **not** technically enforce read-only behavior;
downstream Vercel credential authority remains authoritative. Prefer the
narrowest Vercel scope available.

## What this is / is not

| This is | This is not |
|---------|-------------|
| Deployment-owned Sanity credential fulfillment | PADE-core Sanity provider |
| Cursor→GCP WIF + subject-bound Secret Manager | A second identity mechanism |
| Rehearsal-scoped write Material (`SANITY_API_TOKEN`) | Encoding project/dataset in the broker |
| Explicit capability allowlist (`SANITY_CURSOR_OIDC_SUBJECTS`) | Granting Sanity to every Cursor subject |
| Credential delivery only | Sanity CLI/API calls from the broker image |

## Hygiene

Never commit to this public repository:

- personal usernames / team names
- provider team/account IDs
- actual Cursor OIDC subjects
- actual GCP project IDs/numbers
- actual Sanity project IDs or dataset names
- tokens or PEMs
- unrelated project names discovered during probes

No raw secret belongs in Git, `.env`, generated YAML, logs, or docs.
