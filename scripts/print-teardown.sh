#!/usr/bin/env bash
# Print teardown commands. Does NOT delete anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

SA="$(runtime_sa_email)"
DEPLOYER="$(deployer_sa_email)"
POOL_ID="${WIF_POOL_ID}"
PROVIDER_ID="${WIF_PROVIDER_ID}"

cat <<EOF
# Teardown commands for this broker deployment (run deliberately, one at a time).
# Images are NOT removed when the Cloud Run service is deleted.

gcloud run services delete ${SERVICE} --region=${REGION} --project=${PROJECT_ID}

gcloud secrets delete ${GITHUB_APP_KEY_SECRET} --project=${PROJECT_ID}

gcloud secrets delete ${GA_SA_SECRET} --project=${PROJECT_ID}

gcloud secrets delete ${VERCEL_TOKEN_SECRET} --project=${PROJECT_ID}

gcloud artifacts repositories delete ${AR_REPO} --location=${REGION} --project=${PROJECT_ID}

gcloud iam service-accounts delete ${SA} --project=${PROJECT_ID}

# GitHub Actions WIF / deployer identity (if provisioned via make bootstrap-github-wif)
gcloud iam workload-identity-pools providers delete ${PROVIDER_ID} \\
  --project=${PROJECT_ID} --location=global --workload-identity-pool=${POOL_ID}

gcloud iam workload-identity-pools delete ${POOL_ID} \\
  --project=${PROJECT_ID} --location=global

gcloud iam service-accounts delete ${DEPLOYER} --project=${PROJECT_ID}

# Optional: delete the entire GCP project if it was created only for this broker.
# gcloud projects delete ${PROJECT_ID}
EOF
