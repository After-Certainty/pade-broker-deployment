#!/usr/bin/env bash
# Stage 2: broker liveness on Cloud Run.
#
# PADE exposes GET /healthz. Google Cloud Run reserves some paths ending in "z"
# (including /healthz), so public requests may be intercepted with a Google HTML
# 404 and never reach the container:
#   https://cloud.google.com/run/docs/known-issues
#
# On Cloud Run we therefore:
#   1. Try GET /healthz (works locally / non-GCP)
#   2. If intercepted, confirm broker liveness via unauthenticated POST /v1/resolve → 401
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd curl
URL="${1:-}"
if [[ -z "${URL}" ]]; then
  if command -v gcloud >/dev/null 2>&1; then
    require_project
    load_versions
    URL="$(gcloud run services describe "${SERVICE}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format='value(status.url)' 2>/dev/null || true)"
  fi
fi
if [[ -z "${URL}" ]]; then
  URL="$(broker_url)"
fi
URL="${URL%/}"

echo "==> GET ${URL}/healthz"
BODY_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${HDR_FILE}"' EXIT
HTTP_CODE="$(curl -sS --max-time 30 -D "${HDR_FILE}" -o "${BODY_FILE}" -w '%{http_code}' \
  "${URL}/healthz" || true)"
BODY="$(cat "${BODY_FILE}")"

if [[ "${HTTP_CODE}" == "200" && "${BODY}" == "ok" ]]; then
  echo "body: ${BODY}"
  echo "Stage 2 OK"
  exit 0
fi

# Detect Cloud Run / GFE reserved-path interception (HTML 404, no app JSON/plain ok).
if [[ "${HTTP_CODE}" == "404" ]] && grep -qi 'text/html' "${HDR_FILE}"; then
  echo "note: GET /healthz returned HTML 404 (Cloud Run reserved path ending in 'z')."
  echo "      Confirming broker liveness via POST /v1/resolve (expect 401)."
  RESOLVE_CODE="$(curl -sS --max-time 30 -o "${BODY_FILE}" -w '%{http_code}' \
    -X POST "${URL}/v1/resolve" \
    -H 'Content-Type: application/json' \
    -d '{"capability":"github.repo.read"}')"
  RESOLVE_BODY="$(cat "${BODY_FILE}")"
  echo "POST /v1/resolve → HTTP ${RESOLVE_CODE} body=${RESOLVE_BODY}"
  if [[ "${RESOLVE_CODE}" == "401" ]]; then
    echo "Stage 2 OK (broker reachable; /healthz intercepted by Cloud Run)"
    exit 0
  fi
  echo "error: broker did not return 401 on unauthenticated resolve" >&2
  exit 1
fi

echo "error: unexpected /healthz response HTTP ${HTTP_CODE} body=${BODY}" >&2
exit 1
