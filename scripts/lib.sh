#!/usr/bin/env bash
# Shared helpers for deployment scripts. Sourced, not executed.
# shellcheck shell=bash

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  if [[ -f "${_REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${_REPO_ROOT}/.env"
    set +a
  fi
}

load_versions() {
  # versions.env first, then .env overrides non-secret deployment settings.
  set -a
  # shellcheck disable=SC1091
  source "${_REPO_ROOT}/versions.env"
  set +a
  load_env
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || {
      echo "error: required command not found: ${c}" >&2
      exit 1
    }
  done
}

require_project() {
  load_versions
  if [[ -z "${PROJECT_ID:-}" || "${PROJECT_ID}" == "your-gcp-project-id" ]]; then
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if [[ -z "${PROJECT_ID:-}" || "${PROJECT_ID}" == "(unset)" ]]; then
    echo "error: set PROJECT_ID in .env or: gcloud config set project PROJECT_ID" >&2
    exit 1
  fi
  export PROJECT_ID
  if [[ -z "${PROJECT_NUMBER:-}" ]]; then
    PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  fi
  export PROJECT_NUMBER
}

broker_url() {
  require_project
  load_versions
  echo "https://${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
}

# Released upstream pade-broker image (digest-pinned when BROKER_IMAGE_DIGEST is set).
broker_image() {
  load_versions
  if [[ -n "${BROKER_IMAGE_DIGEST:-}" ]]; then
    echo "${BROKER_IMAGE}@${BROKER_IMAGE_DIGEST}"
  else
    echo "${BROKER_IMAGE}:${PADE_VERSION}"
  fi
}

# Private overlay image (exec providers + policy/bindings) in your Artifact Registry.
runtime_image() {
  load_versions
  require_project
  echo "${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${RUNTIME_IMAGE_NAME}:${PADE_VERSION}"
}

runtime_sa_email() {
  load_versions
  require_project
  echo "${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
}

bindings_file() {
  echo "${_REPO_ROOT}/config/.generated/broker-bindings.yaml"
}

# Relative to repo root — Docker COPY context.
bindings_file_rel() {
  echo "config/.generated/broker-bindings.yaml"
}

policy_file() {
  echo "${_REPO_ROOT}/config/.generated/broker-policy.yaml"
}

policy_file_rel() {
  echo "config/.generated/broker-policy.yaml"
}
