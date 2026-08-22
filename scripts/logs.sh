#!/usr/bin/env bash
# Print Cloud Run logs for the broker service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud
require_project
load_versions

LIMIT="${1:-50}"

gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${SERVICE}\" AND textPayload:\"pade-broker:\"" \
  --project="${PROJECT_ID}" \
  --limit="${LIMIT}" \
  --format='value(timestamp,textPayload)' \
  --freshness=1d
