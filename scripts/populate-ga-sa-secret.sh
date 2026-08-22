#!/usr/bin/env bash
# Populate or rotate the Google Analytics service account JSON in Secret Manager.
#
# Reads JSON from stdin or GOOGLE_ANALYTICS_SA_JSON environment variable.
# Never prints the secret value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

SECRET_NAME="${GA_SA_SECRET:-google-analytics-sa}"
RUNTIME_SA_EMAIL="$(runtime_sa_email)"

if [[ -n "${GOOGLE_ANALYTICS_SA_JSON:-}" ]]; then
  DATA="${GOOGLE_ANALYTICS_SA_JSON}"
elif [[ ! -t 0 ]]; then
  DATA="$(cat)"
  if [[ -z "${DATA}" ]]; then
    echo "error: empty stdin; expected service account JSON" >&2
    exit 1
  fi
else
  echo "error: provide service account JSON via GOOGLE_ANALYTICS_SA_JSON or stdin" >&2
  echo "  GOOGLE_ANALYTICS_SA_JSON=\"\$(cat sa.json)\" make secret-ga-sa" >&2
  exit 1
fi

if gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  printf '%s' "${DATA}" | gcloud secrets versions add "${SECRET_NAME}" \
    --project="${PROJECT_ID}" \
    --data-file=-
  echo "Added new version to secret ${SECRET_NAME}"
else
  printf '%s' "${DATA}" | gcloud secrets create "${SECRET_NAME}" \
    --project="${PROJECT_ID}" \
    --replication-policy=automatic \
    --data-file=-
  echo "Created secret ${SECRET_NAME}"
fi

gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

echo "Granted roles/secretmanager.secretAccessor on ${SECRET_NAME} to ${RUNTIME_SA_EMAIL}"
