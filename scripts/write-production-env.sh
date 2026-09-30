#!/usr/bin/env bash
# Write deployment .env from GitHub Environment variables (identifiers only).
# PEMs / SA JSON / Vercel tokens stay in Secret Manager.
# AWS S3 values are non-secret identifiers (role ARN contains an account ID but
# is not a credential). No AWS access keys belong here or in GitHub Secrets.
set -euo pipefail

required=(
  PROJECT_ID
  PROJECT_NUMBER
  GITHUB_APP_ID
  GITHUB_APP_INSTALLATION_ID
  GITHUB_REPOSITORIES
  GA_PROPERTY_ID
  GCE_OIDC_SUBJECT
  AWS_S3_ROLE_ARN
  AWS_S3_BUCKET
  AWS_S3_REGION
  AWS_S3_AUDIENCE
)

for v in "${required[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "error: GitHub Environment variable ${v} is unset (environment: production)" >&2
    exit 1
  fi
done

if [[ -z "${CURSOR_OIDC_SUBJECTS:-}" && -z "${CURSOR_OIDC_SUBJECT:-}" ]]; then
  echo "error: GitHub Environment variable CURSOR_OIDC_SUBJECTS or CURSOR_OIDC_SUBJECT must be set (environment: production)" >&2
  exit 1
fi

{
  echo "PROJECT_ID=${PROJECT_ID}"
  echo "PROJECT_NUMBER=${PROJECT_NUMBER}"
  echo "GITHUB_APP_ID=${GITHUB_APP_ID}"
  echo "GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID}"
  echo "GITHUB_REPOSITORIES=${GITHUB_REPOSITORIES}"
  echo "GA_PROPERTY_ID=${GA_PROPERTY_ID}"
  echo "GCE_OIDC_SUBJECT=${GCE_OIDC_SUBJECT}"
  if [[ -n "${CURSOR_OIDC_SUBJECT:-}" ]]; then
    echo "CURSOR_OIDC_SUBJECT=${CURSOR_OIDC_SUBJECT}"
  fi
  if [[ -n "${CURSOR_OIDC_SUBJECTS:-}" ]]; then
    echo "CURSOR_OIDC_SUBJECTS=${CURSOR_OIDC_SUBJECTS}"
  fi
  echo "AWS_S3_ROLE_ARN=${AWS_S3_ROLE_ARN}"
  echo "AWS_S3_BUCKET=${AWS_S3_BUCKET}"
  echo "AWS_S3_REGION=${AWS_S3_REGION}"
  echo "AWS_S3_AUDIENCE=${AWS_S3_AUDIENCE}"
} > .env
