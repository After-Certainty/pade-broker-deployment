#!/usr/bin/env bash
# Populate or rotate the GitHub App private key PEM in Google Secret Manager.
#
# Reads PEM from stdin or GITHUB_APP_PRIVATE_KEY environment variable.
# Never prints the secret value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

SECRET_NAME="${GITHUB_APP_KEY_SECRET:-github-app-private-key}"
RUNTIME_SA_EMAIL="$(runtime_sa_email)"

if [[ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]]; then
  DATA="${GITHUB_APP_PRIVATE_KEY}"
elif [[ ! -t 0 ]]; then
  DATA="$(cat)"
  if [[ -z "${DATA}" ]]; then
    echo "error: empty stdin; expected GitHub App private key PEM" >&2
    exit 1
  fi
else
  echo "error: provide the App private key via GITHUB_APP_PRIVATE_KEY or stdin" >&2
  echo "  GITHUB_APP_PRIVATE_KEY=\"\$GITHUB_APP_PRIVATE_KEY\" make secret-github-app" >&2
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
