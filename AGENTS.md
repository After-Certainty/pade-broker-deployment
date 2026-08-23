# AGENTS.md

## Cursor Cloud specific instructions

This repo is **deployment tooling** (Bash + `make` wrappers around `docker` and
`gcloud`), not a long-running app. It builds a runtime overlay image on top of
the released PADE broker (`ghcr.io/after-certainty/pade-broker`) and deploys it to
Google Cloud Run. The "product" you can run locally is the broker container
this repo builds. See `README.md` for the full deploy workflow and `Makefile`
for all targets.

### PADE boundary

- **Vercel belongs in this deployment repo**, not in PADE. Do not add Vercel
  providers, schemas, SDKs, or vocabulary to `After-Certainty/pade`.
- Consume **released** PADE artifacts (digest-pinned in `versions.env`). Do not
  rebuild the broker from source here without a deliberate, documented reason.
- Change PADE only when you can demonstrate a **generic** deficiency (not a
  vendor-specific wish). If you find one, stop and describe it rather than
  patching PADE from this repo by default.

### Vercel modes

- **Recommended / template default:** `fulfillment: subject-secret-wif`
  (Cursor OIDC → GCP WIF → subject Secret Manager → Material).
- **Optional compatibility:** `static-token-file` + `MOUNT_SHARED_VERCEL_TOKEN=1`
  (shared mounted token; Milestone L proof / local fallback).
- When `fulfillment` is omitted, the Go provider falls back to `static-token-file`
  for compatibility; deployed bindings always set `subject-secret-wif`.

### What runs where (scope)

- **Local (no cloud creds needed):** lint scripts, `make test-providers`,
  `make render-config`, `make predict-url`, `make print-agent-bindings`,
  `make pull-broker`, `make build`, and running the built image with `docker run`.
- **Requires the user's real GCP project + secrets (out of scope for local
  dev):** `make bootstrap-gcp`, `make bootstrap-cursor-wif`, `make push`,
  `make deploy`, `make secret-*`, `make health`/`authz-smoke`/`logs` against the
  deployed URL. These need a billed GCP project, `gcloud` auth, a GitHub App PEM,
  a GA service-account JSON, and (for Vercel) either per-subject tokens or an
  optional shared token — none of which are present in this VM by default.

### Docker daemon (must be started each boot)

The Docker daemon is installed but is **not auto-started** by the update
script. Start it once per VM boot before any `docker`/`make build` work:

```bash
sudo dockerd >/tmp/dockerd.log 2>&1 &   # or run `sudo dockerd` in a tmux session
sudo chmod 666 /var/run/docker.sock      # allow non-root `docker` (Makefile calls `docker`, not `sudo docker`)
```

Docker is configured for this VM in `/etc/docker/daemon.json` with
`storage-driver: fuse-overlayfs` and `containerd-snapshotter: false` (required
for fuse-overlayfs on Docker 29 inside the Firecracker VM). Do not remove that
config.

### Local dev `.env` (gitignored)

`make render-config` / `make build` read `.env` and reject placeholder values.
For offline dev, create a `.env` with valid-format **non-secret placeholders**
and set **both** `PROJECT_ID` and `PROJECT_NUMBER` so `require_project()` in
`scripts/lib.sh` does not call `gcloud`:

```bash
cat > .env <<'EOF'
PROJECT_ID=pade-dev-local
PROJECT_NUMBER=123456789012
GITHUB_APP_ID=100001
GITHUB_APP_INSTALLATION_ID=200002
GITHUB_REPOSITORIES=After-Certainty/pade
GA_PROPERTY_ID=properties/987654321
CURSOR_OIDC_SUBJECT=user:dev-local-subject
EOF
```

Rendered output lands in `config/.generated/` (gitignored). Replace with real
identifiers before any real deploy.

Do **not** put a Vercel token in `.env`. Use `make secret-vercel-token-subject`
(recommended) or `make secret-vercel-token` (shared / static-token-file only)
with Secret Manager. See `docs/milestone-m-wif.md` and `docs/milestone-l-vercel.md`.

### Deployment-owned providers

`providers/vercel/` is a stdlib-only Go exec provider built into the runtime
overlay. Local checks:

```bash
make test-providers   # or: cd providers/vercel && go test ./...
```

Uses only fake tokens. Requires Go on the host (Docker build uses `golang:1.26`
and does not need host Go for `make build`).

### Build + run the broker locally (the local "hello world")

```bash
make build            # render config + pull GHCR broker + docker build overlay
                      # image tag: <REGION>-docker.pkg.dev/<PROJECT_ID>/<AR_REPO>/pade-broker-runtime:<PADE_VERSION>
docker run -d --name pade-broker-local -p 8080:8080 \
  "$(source scripts/lib.sh && runtime_image)" \
  -tls-termination=proxy -policy /config/policy.yaml -bindings /config/bindings.yaml \
  -resolve-timeout 25s -max-concurrent-resolves 32
```

Non-obvious runtime notes:

- The broker binary is `/pade-broker`, listens on `PORT` (default `8080`), runs
  as `nonroot`. The exec providers only run on `/v1/resolve`, so the container
  starts and serves `/healthz` fine **without** the Secret Manager mounts.
- Validate against the local container by passing the URL as `$1` (do **not**
  use `make health` alone — with no URL it targets the predicted, non-deployed
  Cloud Run URL and fails):
  - `./scripts/health.sh http://localhost:8080` → `200` + `ok`
  - `./scripts/authz-smoke.sh http://localhost:8080` → `401 {"error":"missing_bearer"}`
- Secret-bearing validation must **never** print credentials (no JWTs, Vercel
  tokens, PEMs, or SA JSON in logs or chat).

### Lint

`shellcheck scripts/*.sh` (the scripts carry `# shellcheck` directives). Runs
clean today.
