#!/usr/bin/env bash
# Stage 3: POST /v1/resolve without OIDC must be rejected (401).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd curl
URL="${1:-}"
if [[ -z "${URL}" ]]; then
  URL="$(broker_url)"
fi

echo "==> POST ${URL}/v1/resolve (no Authorization)"
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
# Capture status without failing curl on 401
HTTP_CODE="$(curl -sS --max-time 30 -o "${BODY_FILE}" -w '%{http_code}' \
  -X POST "${URL}/v1/resolve" \
  -H 'Content-Type: application/json' \
  -d '{"capability":"github.repo.read"}')"
BODY="$(cat "${BODY_FILE}")"

echo "HTTP ${HTTP_CODE}"
echo "body: ${BODY}"

if [[ "${HTTP_CODE}" != "401" ]]; then
  echo "error: expected HTTP 401, got ${HTTP_CODE}" >&2
  exit 1
fi
echo "Stage 3 OK (unauthenticated resolve rejected)"
