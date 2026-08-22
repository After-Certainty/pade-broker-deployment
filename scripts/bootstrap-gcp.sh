#!/usr/bin/env bash
# Idempotent GCP bootstrap for a PADE broker Cloud Run deployment.
# Enables APIs, creates Artifact Registry repo, runtime SA, and deployer IAM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud
require_project
load_versions

echo "==> Project ${PROJECT_ID} (number ${PROJECT_NUMBER})"
echo "==> Region ${REGION}"

echo "==> Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Artifact Registry repository ${AR_REPO}"
if gcloud artifacts repositories describe "${AR_REPO}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    already exists"
else
  gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="PADE broker container images" \
    --project="${PROJECT_ID}"
fi

RUNTIME_SA_EMAIL="$(runtime_sa_email)"
echo "==> Runtime service account ${RUNTIME_SA_EMAIL}"
if gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    already exists"
else
  gcloud iam service-accounts create "${RUNTIME_SA_NAME}" \
    --display-name="PADE broker Cloud Run runtime" \
    --project="${PROJECT_ID}"
fi

# Deployer must be able to act as the runtime SA when deploying Cloud Run.
DEPLOYER="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -n "${DEPLOYER}" ]]; then
  echo "==> Granting roles/iam.serviceAccountUser on runtime SA to ${DEPLOYER}"
  gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --member="user:${DEPLOYER}" \
    --role="roles/iam.serviceAccountUser" \
    --quiet >/dev/null
else
  echo "warning: could not detect gcloud account; grant iam.serviceAccountUser on ${RUNTIME_SA_EMAIL} manually" >&2
fi

# If broker-side secrets already exist, ensure runtime SA can read them.
for SECRET_NAME in "${GITHUB_APP_KEY_SECRET}" "${GA_SA_SECRET}" "${VERCEL_TOKEN_SECRET}"; do
  if gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "==> Granting secretAccessor on existing ${SECRET_NAME}"
    gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
      --project="${PROJECT_ID}" \
      --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
      --role="roles/secretmanager.secretAccessor" \
      --quiet >/dev/null
  else
    echo "==> Secret ${SECRET_NAME} not created yet (see README secret setup)"
  fi
done

echo "==> Predicted broker URL:"
"${ROOT}/scripts/predict-broker-url.sh"
echo "Bootstrap complete."
