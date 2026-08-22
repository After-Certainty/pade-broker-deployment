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
CURSOR_POOL_ID="${CURSOR_WIF_POOL_ID:-pade-broker-cursor}"
CURSOR_PROVIDER_ID="${CURSOR_WIF_PROVIDER_ID:-cursor}"

cat <<EOF
# Teardown commands for this broker deployment (run deliberately, one at a time).
# Images are NOT removed when the Cloud Run service is deleted.

gcloud run services delete ${SERVICE} --region=${REGION} --project=${PROJECT_ID}

gcloud secrets delete ${GITHUB_APP_KEY_SECRET} --project=${PROJECT_ID}

gcloud secrets delete ${GA_SA_SECRET} --project=${PROJECT_ID}

gcloud secrets delete ${VERCEL_TOKEN_SECRET} --project=${PROJECT_ID}

# Milestone M subject-bound Vercel secrets (ids are vercel-token-sub-<hash>):
# gcloud secrets list --project=${PROJECT_ID} --filter='name:vercel-token-sub-' \\
#   --format='value(name)' | xargs -n1 -I{} gcloud secrets delete {} --project=${PROJECT_ID}

gcloud artifacts repositories delete ${AR_REPO} --location=${REGION} --project=${PROJECT_ID}

gcloud iam service-accounts delete ${SA} --project=${PROJECT_ID}

# GitHub Actions WIF / deployer identity (if provisioned via make bootstrap-github-wif)
gcloud iam workload-identity-pools providers delete ${PROVIDER_ID} \\
  --project=${PROJECT_ID} --location=global --workload-identity-pool=${POOL_ID}

gcloud iam workload-identity-pools delete ${POOL_ID} \\
  --project=${PROJECT_ID} --location=global

gcloud iam service-accounts delete ${DEPLOYER} --project=${PROJECT_ID}

# Cursor OIDC WIF (Milestone M; if provisioned via make bootstrap-cursor-wif)
gcloud iam workload-identity-pools providers delete ${CURSOR_PROVIDER_ID} \\
  --project=${PROJECT_ID} --location=global --workload-identity-pool=${CURSOR_POOL_ID}

gcloud iam workload-identity-pools delete ${CURSOR_POOL_ID} \\
  --project=${PROJECT_ID} --location=global

# Optional: delete the entire GCP project if it was created only for this broker.
# gcloud projects delete ${PROJECT_ID}
EOF
