#!/usr/bin/env bash
# Idempotent Cursor OIDC → GCP Workload Identity Federation bootstrap (Milestone M).
# Creates a WIF pool/provider for Cursor workload identity so a deployment-owned
# provider can exchange a Cursor ID token for federated Google credentials and
# read subject-bound Secret Manager material.
#
# Distinct from make bootstrap-github-wif (GitHub Actions → deployer SA).
# Does NOT create long-lived service-account keys.
#
# Requires an already-bootstrapped project (make bootstrap-gcp) and admin gcloud.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud
require_project
load_versions

POOL_ID="${CURSOR_WIF_POOL_ID:-pade-broker-cursor}"
PROVIDER_ID="${CURSOR_WIF_PROVIDER_ID:-cursor}"
ISSUER_URI="${CURSOR_OIDC_ISSUER:-https://api.cursor.com}"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"

# Map Cursor JWT "sub" to google.subject so Secret Manager IAM can bind
# principal://.../subject/<sub> to per-subject secrets.
ATTRIBUTE_MAPPING="google.subject=assertion.sub"

# Broker-forwarded Cursor tokens have aud=<broker URL>. Without listing that
# audience here, STS rejects the exchange (default aud is the provider resource name).
if [[ -z "${BROKER_URL:-}" ]]; then
  BROKER_URL="$(broker_url)"
fi
BROKER_URL="${BROKER_URL%/}"
if [[ -z "${BROKER_URL}" || "${BROKER_URL}" != https://* ]]; then
  echo "error: BROKER_URL must be the Cloud Run HTTPS audience (set in .env or via make predict-url)" >&2
  exit 1
fi
ALLOWED_AUDIENCES="${BROKER_URL}"

echo "==> Project ${PROJECT_ID} (number ${PROJECT_NUMBER})"
echo "==> Cursor WIF pool ${POOL_ID} / provider ${PROVIDER_ID}"
echo "==> Issuer ${ISSUER_URI}"
echo "==> Allowed audiences (Cursor token aud) ${ALLOWED_AUDIENCES}"

echo "==> Enabling APIs (STS + IAM + Secret Manager)"
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Workload Identity Pool ${POOL_ID}"
if gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" >/dev/null 2>&1; then
  echo "    already exists"
else
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="PADE broker Cursor OIDC" \
    --description="Milestone M: Cursor workload OIDC federation for subject-bound provider Material"
fi

echo "==> Workload Identity Provider ${PROVIDER_ID}"
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  echo "    updating issuer, attribute mapping, and allowed audiences (idempotent)"
  gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --issuer-uri="${ISSUER_URI}" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --allowed-audiences="${ALLOWED_AUDIENCES}" \
    --quiet
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="Cursor OIDC" \
    --issuer-uri="${ISSUER_URI}" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --allowed-audiences="${ALLOWED_AUDIENCES}"
fi

cat <<EOF

Bootstrap (Cursor WIF) complete.

Pool:     ${POOL_RESOURCE}
Provider: ${PROVIDER_RESOURCE}
Issuer:   ${ISSUER_URI}
Audiences:${ALLOWED_AUDIENCES}

Next steps (recommended subject-secret-wif path):
  1. Deploy against broker v0.1.1+ (identity forwarding; digest-pinned in versions.env).
  2. Allowlist subjects in .env (CURSOR_OIDC_SUBJECT or CURSOR_OIDC_SUBJECTS).
  3. For each subject:
       SUBJECT='user:…' VERCEL_TOKEN='…' make secret-vercel-token-subject
  4. Bindings template already uses fulfillment: subject-secret-wif — render, build, push, deploy
     (no shared vercel-token mount required). See docs/milestone-m-wif.md.

Federated principal form (Secret Manager IAM):
  principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/subject/SUBJECT

This pool is NOT the GitHub Actions deployer pool (${WIF_POOL_ID}).

If vercel.diagnostics returns broker 502 under subject-secret-wif,
re-run this script so allowed audiences include the broker URL (token aud).
EOF
