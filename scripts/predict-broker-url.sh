#!/usr/bin/env bash
# Print the deterministic Cloud Run HTTPS URL for the broker service.
# Format (official): https://SERVICE_NAME-PROJECT_NUMBER.REGION.run.app
# https://docs.cloud.google.com/run/docs/triggering/https-request
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

url="$(broker_url)"
segment="${SERVICE}-${PROJECT_NUMBER}"
if (( ${#segment} > 63 )); then
  echo "warning: DNS segment '${segment}' is ${#segment} chars (>63); deterministic URL may be unavailable" >&2
fi

echo "${url}"
