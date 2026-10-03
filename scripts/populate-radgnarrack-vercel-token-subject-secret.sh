#!/usr/bin/env bash
# Populate or rotate a subject-bound RadGnaRack Vercel access token in Secret
# Manager. Uses RADGNARRACK_VERCEL_SUBJECT_SECRET_PREFIX — a separate secret
# namespace from make secret-vercel-token-subject (vercel.diagnostics).
#
# Do NOT use this script to rotate the existing vercel.diagnostics credential.
# Do NOT pass VERCEL_TOKEN here — use RADGNARRACK_VERCEL_TOKEN (or stdin).
#
# Grants secretAccessor to the Cursor WIF federated principal for that subject
# — NOT to the Cloud Run runtime service account.
#
# Usage:
#   SUBJECT='user:…' RADGNARRACK_VERCEL_TOKEN='…' make secret-radgnarrack-vercel-token-subject
#
# Prefer history-safe capture:
#   read -rsp "RadGnaRack Vercel token: " RADGNARRACK_VERCEL_TOKEN; echo
#   export RADGNARRACK_VERCEL_TOKEN
#   SUBJECT='user:…' make secret-radgnarrack-vercel-token-subject
#   unset RADGNARRACK_VERCEL_TOKEN
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
  echo "  SUBJECT='user:…' RADGNARRACK_VERCEL_TOKEN='…' make secret-radgnarrack-vercel-token-subject" >&2
  exit 1
fi

# Refuse accidental use of the vercel.diagnostics env var so operators cannot
# silently overwrite or confuse the two authorities.
if [[ -n "${VERCEL_TOKEN:-}" && -z "${RADGNARRACK_VERCEL_TOKEN:-}" && -t 0 ]]; then
  echo "error: VERCEL_TOKEN is set but RADGNARRACK_VERCEL_TOKEN is not" >&2
  echo "hint: this target manages the RadGnaRack Vercel secret namespace only" >&2
  echo "hint: use make secret-vercel-token-subject for vercel.diagnostics" >&2
  echo "hint: set RADGNARRACK_VERCEL_TOKEN (or pipe stdin) for this target" >&2
  exit 1
fi

POOL_ID="${CURSOR_WIF_POOL_ID:-pade-broker-cursor}"
PREFIX="${RADGNARRACK_VERCEL_SUBJECT_SECRET_PREFIX:-vercel-radgnarrack-token-sub}"
DEFAULT_VERCEL_PREFIX="${VERCEL_SUBJECT_SECRET_PREFIX:-vercel-token-sub}"
if [[ "${PREFIX}" == "${DEFAULT_VERCEL_PREFIX}" ]]; then
  echo "error: RADGNARRACK_VERCEL_SUBJECT_SECRET_PREFIX must differ from VERCEL_SUBJECT_SECRET_PREFIX" >&2
  echo "hint: refusing to write into the vercel.diagnostics secret namespace" >&2
  exit 1
fi

SECRET_NAME="$(radgnarrack_vercel_subject_secret_id "${SUBJECT}")"
MEMBER="$(cursor_federated_principal_member "${SUBJECT}")"

if [[ -n "${RADGNARRACK_VERCEL_TOKEN:-}" ]]; then
  DATA="${RADGNARRACK_VERCEL_TOKEN}"
elif [[ ! -t 0 ]]; then
  DATA="$(cat)"
  if [[ -z "${DATA}" ]]; then
    echo "error: empty stdin; expected RadGnaRack Vercel access token" >&2
    exit 1
  fi
else
  echo "error: provide the token via RADGNARRACK_VERCEL_TOKEN or stdin" >&2
  echo "  SUBJECT='…' RADGNARRACK_VERCEL_TOKEN='…' make secret-radgnarrack-vercel-token-subject" >&2
  echo "hint: do not use VERCEL_TOKEN / secret-vercel-token-subject for this authority" >&2
  exit 1
fi

# Trim surrounding whitespace; do not echo value.
DATA="${DATA%"${DATA##*[![:space:]]}"}"
DATA="${DATA#"${DATA%%[![:space:]]*}"}"
if [[ -z "${DATA}" ]]; then
  echo "error: RadGnaRack Vercel token is empty after trim" >&2
  exit 1
fi

echo "==> RadGnaRack Vercel subject-bound secret id ${SECRET_NAME}"
echo "    (prefix=${PREFIX}; derived from SUBJECT; value not printed)"
echo "    (distinct from vercel.diagnostics namespace ${DEFAULT_VERCEL_PREFIX}-…)"

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
echo "Note: runtime SA is intentionally NOT granted accessor on this secret."
echo "Ensure make bootstrap-cursor-wif has been run (pool=${POOL_ID})."
echo "This secret backs vercel.radgnarrack.read — not vercel.diagnostics."
