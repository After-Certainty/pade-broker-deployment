#!/usr/bin/env bash
# Offline assertions about rendered policy only; not an AWS IAM simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/aws-s3-lib.sh"

permission="$(aws_s3_render_permissions_policy ci-security-fixture)"
jq -e '.Version == "2012-10-17" and .Statement == [{
  Effect: "Allow", Action: "s3:PutObject",
  Resource: "arn:aws:s3:::ci-security-fixture/experiment-007/*"
}]' <<<"${permission}" >/dev/null

trust="$(aws_s3_render_trust_policy 123456789012345678901 https://security.example.invalid/aws)"
jq -e '.Version == "2012-10-17" and .Statement == [{
  Effect: "Allow", Principal: {Federated: "accounts.google.com"},
  Action: "sts:AssumeRoleWithWebIdentity",
  Condition: {StringEquals: {
    "accounts.google.com:aud": "123456789012345678901",
    "accounts.google.com:sub": "123456789012345678901",
    "accounts.google.com:oaud": "https://security.example.invalid/aws"
  }}
}]' <<<"${trust}" >/dev/null

# Unsafe bootstrap inputs must fail before an operator invokes cloud commands.
if aws_s3_validate_bucket 'bucket/*' >/dev/null; then exit 1; fi
if aws_s3_validate_audience 'https://security.example.invalid/*' >/dev/null; then exit 1; fi
if aws_s3_validate_google_sub '' >/dev/null; then exit 1; fi
printf 'OK: offline AWS policy rendering contract (not live IAM enforcement)\n'
