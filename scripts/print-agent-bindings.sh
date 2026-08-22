#!/usr/bin/env bash
# Print agent-side broker bindings with this deployment's predicted Cloud Run URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

if [[ -z "${BROKER_URL:-}" ]]; then
  BROKER_URL="$(broker_url)"
fi

EXAMPLE="${ROOT}/agent/broker.bindings.example.yaml"
if [[ ! -f "${EXAMPLE}" ]]; then
  echo "error: missing ${EXAMPLE}" >&2
  exit 1
fi

sed "s|https://YOUR-BROKER-URL|${BROKER_URL}|g" "${EXAMPLE}"
