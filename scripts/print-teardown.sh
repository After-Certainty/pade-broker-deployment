#!/usr/bin/env bash
# Print teardown commands. Does NOT delete anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

SA="$(runtime_sa_email)"

cat <<EOF
# Teardown commands for this broker deployment (run deliberately, one at a time).
# Images are NOT removed when the Cloud Run service is deleted.

gcloud run services delete ${SERVICE} --region=${REGION} --project=${PROJECT_ID}

gcloud secrets delete ${GITHUB_APP_KEY_SECRET} --project=${PROJECT_ID}

gcloud secrets delete ${GA_SA_SECRET} --project=${PROJECT_ID}

gcloud artifacts repositories delete ${AR_REPO} --location=${REGION} --project=${PROJECT_ID}

gcloud iam service-accounts delete ${SA} --project=${PROJECT_ID}

# Optional: delete the entire GCP project if it was created only for this broker.
# gcloud projects delete ${PROJECT_ID}
EOF
