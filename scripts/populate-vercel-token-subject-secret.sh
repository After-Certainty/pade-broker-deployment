#!/usr/bin/env bash
# Populate or rotate a subject-bound Vercel access token in Secret Manager
# (Milestone M). Grants secretAccessor to the Cursor WIF federated principal
# for that subject — NOT to the Cloud Run runtime service account.
#
# Usage:
#   SUBJECT='user:…' VERCEL_TOKEN='…' make secret-vercel-token-subject
#
# Prefer history-safe capture:
#   read -rsp "Vercel token: " VERCEL_TOKEN; echo; export VERCEL_TOKEN
#   SUBJECT='user:…' make secret-vercel-token-subject
#   unset VERCEL_TOKEN
#
# Never prints the secret value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud sha256sum
require_project
load_versions

if [[ -z "${SUBJECT:-}" ]]; then
  echo "error: set SUBJECT to the Cursor OIDC subject (JWT sub)" >&2
  echo "  SUBJECT='user:…' VERCEL_TOKEN='…' make secret-vercel-token-subject" >&2
  exit 1
fi

POOL_ID="${CURSOR_WIF_POOL_ID:-pade-broker-cursor}"
SECRET_NAME="$(vercel_subject_secret_id "${SUBJECT}")"
MEMBER="$(cursor_federated_principal_member "${SUBJECT}")"

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
  echo "  SUBJECT='…' VERCEL_TOKEN='…' make secret-vercel-token-subject" >&2
  exit 1
fi

# Trim surrounding whitespace; do not echo value.
DATA="${DATA%"${DATA##*[![:space:]]}"}"
DATA="${DATA#"${DATA%%[![:space:]]*}"}"
if [[ -z "${DATA}" ]]; then
  echo "error: Vercel token is empty after trim" >&2
  exit 1
fi

echo "==> Subject-bound secret id ${SECRET_NAME}"
echo "    (derived from SUBJECT; value not printed)"

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

echo "==> Granting secretAccessor to federated principal"
echo "    ${MEMBER}"
gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --member="${MEMBER}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

echo "Granted roles/secretmanager.secretAccessor on ${SECRET_NAME} to Cursor WIF principal"
echo "Note: runtime SA is intentionally NOT granted accessor on this secret (Milestone M)."
echo "Ensure make bootstrap-cursor-wif has been run (pool=${POOL_ID})."
