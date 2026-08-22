#!/usr/bin/env bash
# Idempotent GitHub Actions → GCP Workload Identity Federation bootstrap.
# Creates deployer SA, WIF pool/provider, and IAM bindings for production deploys.
# Requires an already-bootstrapped project (make bootstrap-gcp) and admin gcloud.
#
# Does NOT create long-lived service-account keys.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud
require_project
load_versions

# Numeric GitHub claims (stable; prefer over reclaimable repository names).
# Defaults match After-Certainty/pade-broker-deployment; override for forks.
GITHUB_REPOSITORY_ID="${GITHUB_REPOSITORY_ID:-1342370939}"
GITHUB_REPOSITORY_OWNER_ID="${GITHUB_REPOSITORY_OWNER_ID:-319601927}"
# Human-readable repo used only in IAM principalSet member + docs output.
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-After-Certainty/pade-broker-deployment}"
# Production branch ref that may assume the deployer SA via this provider.
GITHUB_PRODUCTION_REF="${GITHUB_PRODUCTION_REF:-refs/heads/master}"

DEPLOYER_SA_EMAIL="$(deployer_sa_email)"
RUNTIME_SA_EMAIL="$(runtime_sa_email)"
POOL_ID="${WIF_POOL_ID}"
PROVIDER_ID="${WIF_PROVIDER_ID}"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"

ATTRIBUTE_CONDITION="assertion.repository_id == '${GITHUB_REPOSITORY_ID}' && assertion.repository_owner_id == '${GITHUB_REPOSITORY_OWNER_ID}' && assertion.ref == '${GITHUB_PRODUCTION_REF}'"
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.ref=assertion.ref"

echo "==> Project ${PROJECT_ID} (number ${PROJECT_NUMBER})"
echo "==> Deployer SA ${DEPLOYER_SA_EMAIL}"
echo "==> WIF trust: repository_id=${GITHUB_REPOSITORY_ID} owner_id=${GITHUB_REPOSITORY_OWNER_ID} ref=${GITHUB_PRODUCTION_REF}"

echo "==> Enabling APIs (WIF + existing deploy surface)"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Deployer service account ${DEPLOYER_SA_EMAIL}"
if gcloud iam service-accounts describe "${DEPLOYER_SA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    already exists"
else
  gcloud iam service-accounts create "${DEPLOYER_SA_NAME}" \
    --display-name="PADE broker GitHub Actions deployer" \
    --description="Deploys pade-broker-runtime via GitHub OIDC / WIF; not the Cloud Run runtime identity" \
    --project="${PROJECT_ID}"
fi

# --- Deployer IAM -----------------------------------------------------------
# TODO(hardening): split --no-invoker-iam-check / one-time invoker config out of
# routine deploy.sh so this identity can drop from roles/run.admin to
# roles/run.developer for day-to-day revision deploys.
echo "==> Granting roles/run.admin on project to deployer"
# Required today: deploy.sh uses --no-invoker-iam-check (run.services.setIamPolicy).
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOYER_SA_EMAIL}" \
  --role="roles/run.admin" \
  --condition=None \
  --quiet >/dev/null

echo "==> Granting roles/artifactregistry.writer on ${AR_REPO}"
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOYER_SA_EMAIL}" \
  --role="roles/artifactregistry.writer" \
  --quiet >/dev/null

echo "==> Granting roles/iam.serviceAccountUser on runtime SA to deployer"
gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOYER_SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --quiet >/dev/null

# Deployer must reference secrets at deploy time (--set-secrets); runtime SA
# still needs secretAccessor to mount them (bootstrap-gcp / populate-* scripts).
for SECRET_NAME in "${GITHUB_APP_KEY_SECRET}" "${GA_SA_SECRET}" "${VERCEL_TOKEN_SECRET}"; do
  if gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "==> Granting secretAccessor on ${SECRET_NAME} to deployer"
    gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
      --project="${PROJECT_ID}" \
      --member="serviceAccount:${DEPLOYER_SA_EMAIL}" \
      --role="roles/secretmanager.secretAccessor" \
      --quiet >/dev/null
  else
    echo "==> Secret ${SECRET_NAME} not created yet; grant secretAccessor to ${DEPLOYER_SA_EMAIL} after populate-*"
  fi
done

# --- Workload Identity Pool + Provider --------------------------------------
echo "==> Workload Identity Pool ${POOL_ID}"
if gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" >/dev/null 2>&1; then
  echo "    already exists"
else
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="PADE broker GitHub Actions" \
    --description="OIDC federation for After-Certainty/pade-broker-deployment production deploys"
fi

echo "==> Workload Identity Provider ${PROVIDER_ID}"
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  echo "    updating attribute mapping/condition (idempotent)"
  gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}" \
    --quiet
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="${ATTRIBUTE_MAPPING}" \
    --attribute-condition="${ATTRIBUTE_CONDITION}"
fi

# Bind GitHub repo principal to deployer SA. Provider attribute-condition already
# restricts to repository_id + owner_id + production ref; principalSet adds a
# second repository-name guard for defense in depth.
WIF_MEMBER="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${GITHUB_REPOSITORY}"
echo "==> Granting roles/iam.workloadIdentityUser on deployer to ${WIF_MEMBER}"
gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER_SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${WIF_MEMBER}" \
  --quiet >/dev/null

cat <<EOF

Bootstrap (GitHub WIF) complete.

Configure GitHub Environment "production" variables:
  GCP_PROJECT_ID=${PROJECT_ID}
  GCP_PROJECT_NUMBER=${PROJECT_NUMBER}
  GCP_WORKLOAD_IDENTITY_PROVIDER=${PROVIDER_RESOURCE}
  GCP_DEPLOYER_SERVICE_ACCOUNT=${DEPLOYER_SA_EMAIL}
  (+ GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_REPOSITORIES,
     GA_PROPERTY_ID, CURSOR_OIDC_SUBJECT — see docs/github-actions.md)

Trust model:
  Provider accepts only repository_id=${GITHUB_REPOSITORY_ID},
  repository_owner_id=${GITHUB_REPOSITORY_OWNER_ID}, ref=${GITHUB_PRODUCTION_REF}.
  No long-lived SA keys. Runtime identity remains ${RUNTIME_SA_EMAIL}.
EOF
