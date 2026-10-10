# Experiment 007 Phase 3 — Broker AWS S3 fulfillment

Deployment-owned fulfillment for `aws.s3.bucket.write` through the Cloud Run PADE
broker. Does **not** modify PADE core or `rc-pade`.

```text
Phase 1 — rc-pade
AWS bucket + direct-test role bootstrap
DONE

Phase 2 — rc-pade
GCE identity → AWS STS → ordinary PutObject
DONE

Phase 3 — pade-broker-deployment
GCE caller identity
    ↓
PADE broker authn/authz
    ↓
Cloud Run runtime identity
    ↓
AWS STS
    ↓
temporary Material
    ↓
ordinary PutObject
THIS WORK
```

## Two identities (do not collapse)

| Identity | Role |
|----------|------|
| **Coder/GCE service account** | Proves who is requesting the PADE capability (`broker.identity: gce`). Authenticates to the broker only. |
| **Cloud Run runtime service account** (`pade-broker-runtime@…`) | Proves which trusted broker provider may assume the Phase 3 AWS role. Mints the Google ID token used with AWS STS. |

The caller's broker-audience ID token must **never** be used as the AWS STS
subject token. If AWS trusted that token directly, the GCE workload could call
STS without the broker and PADE would not be the authority boundary.

## Three trust paths (do not conflate)

| Path | What it is |
|------|------------|
| GitHub Actions → GCP deploy WIF | CI/CD pushes/deploys Cloud Run (`pade-broker-github`) |
| Cursor → GCP WIF | Vercel subject-secret Material (`pade-broker-cursor`) |
| Cloud Run runtime → AWS STS | This experiment (`aws.s3.bucket.write`) |

## Provider

Binary: `/providers/pade-provider-aws-s3` (stdlib Go under [`providers/aws-s3/`](../providers/aws-s3/)).

1. Require capability `aws.s3.bucket.write`
2. Require broker-verified `identity.issuerAlias == "google"` (and issuer URL when set)
3. Mint Google ID token from Cloud Run metadata for `config.audience` (`AWS_S3_AUDIENCE`)
4. `AssumeRoleWithWebIdentity` (900s) — no access keys, profiles, or ambient AWS creds
5. Return Material: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
   `AWS_REGION`, plus platform binding `AWS_S3_BUCKET`, `AWS_S3_PREFIX`
6. Optional `expiresAt` from STS (broker HTTP wire may still expose `env` only)

Never logs caller JWT, runtime JWT, or AWS secrets.

## Phase 3 AWS role

| Item | Value |
|------|--------|
| Role name | `pade-broker-experiment-007-s3-write` (**not** Phase 2 `pade-experiment-007-s3-write`) |
| Permission | `s3:PutObject` only on `arn:aws:s3:::after-certainty-rc-pade-007-1abcdf/experiment-007/*` |
| Federated principal | `accounts.google.com` |
| Trust conditions | `sub` + `aud` = Cloud Run runtime SA **unique ID** (via gcloud); `oaud` = `AWS_S3_AUDIENCE` |

AWS Google claim mapping (when `azp` is present):

| AWS condition key | Google claim |
|-------------------|--------------|
| `accounts.google.com:aud` | `azp` |
| `accounts.google.com:oaud` | `aud` |
| `accounts.google.com:sub` | `sub` |

If a live Cloud Run metadata token has `azp` ≠ runtime SA unique ID, **stop and
report** — do not broaden the trust policy.

## Operator bootstrap (workstation; before merge)

Requires `gcloud` (GCP project) + `aws` CLI (AWS account). **Not** GitHub Actions.

```bash
# Optional: confirm runtime SA exists
make bootstrap-gcp

make check-aws-s3          # derive uniqueId; show expected trust; no mutation
make bootstrap-aws-s3      # create/reconcile Phase 3 role only
make show-aws-s3           # print AWS_S3_ROLE_ARN to record
```

Then set GitHub Environment **`production`** variables (non-secret):

| Variable | Value |
|----------|--------|
| `AWS_S3_ROLE_ARN` | ARN from `make show-aws-s3` |
| `AWS_S3_BUCKET` | `after-certainty-rc-pade-007-1abcdf` |
| `AWS_S3_REGION` | `us-east-1` |
| `AWS_S3_AUDIENCE` | `https://pade-broker-aws-s3.after-certainty.aws` |

Also confirm existing production variables remain configured. **No** GitHub Secrets
are required for AWS or GCP credentials (deploy continues to use GitHub→GCP WIF).

Teardown (Phase 3 role only): `make teardown-aws-s3`.

## Pre-merge checklist

Because merge to `master` triggers production deploy automatically:

1. [ ] `make bootstrap-aws-s3` from workstation
2. [ ] Record new role ARN
3. [ ] Add/update GitHub Environment `production` vars listed above
4. [ ] Verify existing production vars still present
5. [ ] Confirm no GitHub Secrets needed for AWS/GCP credentials
6. [ ] PR CI green (credential-free)

## Post-merge validation (GCE Coder only)

Push to `master` deploys the broker. Validate from the GCE-backed Coder workspace
(not GitHub Actions):

```bash
# Agent bindings (includes aws.s3.bucket.write + identity: gce)
make print-agent-bindings-gce
# Copy into the workspace PADE_BINDINGS / agent bindings file.
```

Acceptance:

```bash
pade exec --capability aws.s3.bucket.write -- python3 - <<'PY'
import os, sys, tempfile
from pathlib import Path

required = [
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AWS_REGION", "AWS_S3_BUCKET", "AWS_S3_PREFIX",
]
missing = [k for k in required if not os.environ.get(k)]
if missing:
    print("missing:", ",".join(missing), file=sys.stderr)
    sys.exit(1)

# Ordinary boto3 PutObject (same shape as rc-pade experiments/003 storage.upload).
import boto3
bucket = os.environ["AWS_S3_BUCKET"]
prefix = os.environ["AWS_S3_PREFIX"]
key = prefix + "broker-fulfillment-proof.txt"
body = b"experiment-007-phase-3-broker-fulfillment\n"
client = boto3.client("s3")
etag = client.put_object(Bucket=bucket, Key=key, Body=body)["ETag"]
print("deployed-gce-broker-aws-s3: success")
print("object_key:", key)
print("etag_present:", bool(etag))
PY
```

Prefer reusing
`rc-pade/experiments/003-source-to-session/app/storage.py` when that tree is on
the workspace path. Do **not** manually inject AWS credentials into Coder.

### Negative checks (where practical)

- Unauthorized / Cursor subjects cannot resolve `aws.s3.bucket.write`
- `PutObject` outside `experiment-007/` denied
- `ListObjectsV2` denied
- No ambient AWS credentials on the Coder VM outside the `pade exec` child
- Broker logs contain no Google/AWS credential material

Do not broaden AWS IAM to make negatives easier.

## Stopping conditions

Stop and report instead of widening authority if:

- Cloud Run metadata cannot mint a token for `AWS_S3_AUDIENCE`
- AWS rejects the runtime SA token under the expected claim mapping
- The provider would need AWS access keys
- Fulfillment would require changing PADE core
- Broker identity context cannot distinguish the allowed GCE caller
- Production deploy would need durable credentials in GitHub

A failed experiment is a valid result.

## CI

PR CI remains credential-free: provider unit tests (fake metadata + fake STS),
config contract (GCE has AWS; Cursor does not), render + overlay build. No live
GCE metadata, AWS, or Cloud Run deploy from CI.

## Shared authority boundary

Distinct broker-authorized callers using this binding receive the same effective
AWS role scope. `AWS_S3_BUCKET`/`AWS_S3_PREFIX` guide the application but do not
restrict a malicious client; downstream IAM must enforce them. This path does not
promise per-subject prefixes or tenant isolation. See the [pinned investigation
and offline evidence](security-boundary-investigation.md).
