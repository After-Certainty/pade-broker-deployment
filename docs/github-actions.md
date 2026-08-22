# Later: GitHub Actions + Workload Identity Federation

**Status: deferred.** Do not require Actions for the first deploy.
Use `make build` / `make push` / `make deploy` first.

## Target shape

```text
push/tag
  → GitHub Actions
  → checkout this repo only
  → docker pull ghcr.io/ksteffe/pade-broker@<digest>   (released broker — no source build)
  → make render-config   (policy/bindings from env; not committed with real IDs)
  → docker build docker/Dockerfile.runtime (overlay: exec providers + rendered config)
  → authenticate to GCP via GitHub OIDC / WIF (no SA keys)
  → push Artifact Registry (runtime overlay only)
  → gcloud run deploy / google-github-actions/deploy-cloudrun
```

## Official guidance

- [Workload Identity Federation with deployment pipelines](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)
- [`google-github-actions/auth`](https://github.com/google-github-actions/auth)
- [`google-github-actions/deploy-cloudrun`](https://github.com/google-github-actions/deploy-cloudrun)

## Sketch (not checked in as a live workflow yet)

1. Create a WIF pool + OIDC provider for `https://token.actions.githubusercontent.com/`.
2. Restrict with an attribute condition on the repository that runs the workflow.
3. Create a **deploy** service account (separate from runtime SA) with:
   - `roles/run.developer` (or admin if setting IAM)
   - Artifact Registry writer on `pade`
   - `roles/iam.serviceAccountUser` on `pade-broker-runtime@…`
4. Grant the GitHub principal `roles/iam.workloadIdentityUser` on the deploy SA.
5. Workflow permissions: `id-token: write`, `contents: read`.
6. Pin `PADE_VERSION`, `BROKER_IMAGE_DIGEST`, and `PADE_REF` from `versions.env`.
7. Supply deployment identifiers (`PROJECT_ID`, GitHub App ids, GA property, Cursor subject) as Actions variables or secrets — not committed YAML.
8. Never store a long-lived GCP service-account JSON key in GitHub Secrets.

Policy/bindings are rendered from env at build time (`make render-config`) and
copied into the overlay image. Bootstrap secrets (GitHub App PEM, GA service
account JSON) stay in Secret Manager and are referenced at deploy time — not
injected by CI plaintext.
