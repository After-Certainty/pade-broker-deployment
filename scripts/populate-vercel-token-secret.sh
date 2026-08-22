#!/usr/bin/env bash
# Populate or rotate the Vercel access token in Google Secret Manager.
#
# Reads the token from stdin or VERCEL_TOKEN environment variable.
# Never prints the secret value.
#
# Prefer capturing without shell history:
#   read -rsp "Vercel token: " VERCEL_TOKEN
#   echo
#   export VERCEL_TOKEN
#   make secret-vercel-token
#   unset VERCEL_TOKEN
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

SECRET_NAME="${VERCEL_TOKEN_SECRET:-vercel-token}"
RUNTIME_SA_EMAIL="$(runtime_sa_email)"

if [[ -n "${VERCEL_TOKEN:-}" ]]; then
  DATA="${VERCEL_TOKEN}"
elif [[ ! -t 0 ]]; then
  DATA="$(cat)"
  if [[ -z "${DATA}" ]]; then
    echo "error: empty stdin; expected Vercel access token" >&2
    exit 1
  fi
else
  echo "error: provide the Vercel token via VERCEL_TOKEN or stdin" >&2
  echo "  read -rsp \"Vercel token: \" VERCEL_TOKEN && echo && export VERCEL_TOKEN && make secret-vercel-token && unset VERCEL_TOKEN" >&2
  exit 1
fi

# Trim trailing newlines commonly introduced by paste/echo; do not echo value.
DATA="${DATA%"${DATA##*[![:space:]]}"}"
DATA="${DATA#"${DATA%%[![:space:]]*}"}"
if [[ -z "${DATA}" ]]; then
  echo "error: Vercel token is empty after trim" >&2
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
