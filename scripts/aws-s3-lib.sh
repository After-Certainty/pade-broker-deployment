#!/usr/bin/env bash
# Shared helpers for Experiment 007 Phase 3 AWS S3 broker-fulfillment bootstrap.
# Source, do not execute. Never prints credential material.
#
# Phase 3 creates/reconciles ONLY the broker runtime IAM role. It does not
# create or modify the Phase 1/2 bucket or the Phase 2 role
# pade-experiment-007-s3-write.
# shellcheck shell=bash

_AWS_S3_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AWS_S3_ROOT="$(cd "${_AWS_S3_SCRIPTS_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${_AWS_S3_SCRIPTS_DIR}/lib.sh"

AWS_S3_PREFIX="experiment-007/"
# shellcheck disable=SC2034 # used by scripts that source this file
AWS_S3_POLICY_NAME="experiment-007-broker-s3-put-object"
AWS_S3_DEFAULT_ROLE_NAME="pade-broker-experiment-007-s3-write"
AWS_S3_PHASE2_ROLE_NAME="pade-experiment-007-s3-write"
AWS_S3_GOOGLE_PROVIDER="accounts.google.com"
AWS_S3_TAG_PROJECT="pade-broker-deployment"
AWS_S3_TAG_EXPERIMENT="007"
AWS_S3_TAG_PURPOSE="broker-aws-s3-fulfillment"
AWS_S3_DEFAULT_BUCKET="after-certainty-rc-pade-007-1abcdf"
AWS_S3_DEFAULT_AUDIENCE="https://pade-broker-aws-s3.after-certainty.aws"
AWS_S3_DEFAULT_REGION="us-east-1"

aws_s3_log() { printf '%s\n' "$*" >&2; }
aws_s3_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

AWS_S3_TMPDIR=""

aws_s3_init_tmp() {
  AWS_S3_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/pade-broker-aws-s3.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${AWS_S3_TMPDIR}'" EXIT
}

aws_s3_mktemp() {
  [[ -n "${AWS_S3_TMPDIR}" ]] || aws_s3_die "aws_s3_init_tmp was not called"
  mktemp "${AWS_S3_TMPDIR}/${1:-tmp}.XXXXXX"
}

aws_s3_load_config() {
  require_project
  load_versions
  AWS_S3_BUCKET="${AWS_S3_BUCKET:-${AWS_S3_DEFAULT_BUCKET}}"
  AWS_S3_ROLE_NAME="${AWS_S3_ROLE_NAME:-${AWS_S3_DEFAULT_ROLE_NAME}}"
  AWS_S3_AUDIENCE="${AWS_S3_AUDIENCE:-${AWS_S3_DEFAULT_AUDIENCE}}"
  : "${AWS_S3_REGION:=${AWS_S3_DEFAULT_REGION}}"
  AWS_S3_RUNTIME_SA_EMAIL="$(runtime_sa_email)"
  # Google unique ID is derived via gcloud during check/bootstrap — never guessed here.
  AWS_S3_GOOGLE_SUB="${AWS_S3_GOOGLE_SUB:-}"
  export AWS_S3_BUCKET AWS_S3_ROLE_NAME AWS_S3_AUDIENCE AWS_S3_REGION AWS_S3_RUNTIME_SA_EMAIL
}

aws_s3_resolve_region() {
  local region="${AWS_S3_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
  if [[ -z "${region}" ]]; then
    region="${AWS_S3_DEFAULT_REGION}"
  fi
  printf '%s' "${region}"
}

aws_s3_validate_bucket() {
  local b="$1"
  if [[ -z "${b}" ]]; then
    echo "AWS_S3_BUCKET is not set"
    return 1
  fi
  if ((${#b} < 3 || ${#b} > 63)) ||
    [[ ! "${b}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] ||
    [[ "${b}" == *..* ]]; then
    echo "AWS_S3_BUCKET is not a valid S3 bucket name: ${b}"
    return 1
  fi
}

aws_s3_validate_role_name() {
  local r="$1"
  if [[ -z "${r}" || ! "${r}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]]; then
    echo "AWS_S3_ROLE_NAME is not a valid IAM role name: ${r}"
    return 1
  fi
  if [[ "${r}" == "${AWS_S3_PHASE2_ROLE_NAME}" ]]; then
    echo "AWS_S3_ROLE_NAME must not be the Phase 2 role ${AWS_S3_PHASE2_ROLE_NAME}"
    return 1
  fi
}

aws_s3_validate_google_sub() {
  local s="$1"
  if [[ -z "${s}" ]]; then
    echo "Cloud Run runtime service-account unique ID is unset (derive via gcloud)"
    return 1
  fi
  if [[ ! "${s}" =~ ^[0-9]{1,64}$ ]]; then
    echo "runtime service-account unique ID must be numeric"
    return 1
  fi
}

aws_s3_validate_audience() {
  local a="$1"
  if [[ -z "${a}" ]]; then
    echo "AWS_S3_AUDIENCE is not set"
    return 1
  fi
  if ((${#a} > 256)) || [[ "${a}" =~ [[:space:]] || "${a}" == *'*'* || "${a}" == *'?'* ]]; then
    echo "AWS_S3_AUDIENCE must be a single literal value without whitespace or wildcards"
    return 1
  fi
}

aws_s3_validate_bootstrap_inputs() {
  local rc=0
  aws_s3_validate_bucket "${AWS_S3_BUCKET}" || rc=1
  aws_s3_validate_role_name "${AWS_S3_ROLE_NAME}" || rc=1
  aws_s3_validate_google_sub "${AWS_S3_GOOGLE_SUB}" || rc=1
  aws_s3_validate_audience "${AWS_S3_AUDIENCE}" || rc=1
  return "${rc}"
}

# Derive Cloud Run runtime SA unique ID. Never guess.
aws_s3_derive_runtime_unique_id() {
  require_cmd gcloud
  local email="${AWS_S3_RUNTIME_SA_EMAIL}"
  local uid
  uid="$(gcloud iam service-accounts describe "${email}" \
    --project="${PROJECT_ID}" \
    --format='value(uniqueId)' 2>/dev/null || true)"
  uid="$(printf '%s' "${uid}" | tr -d '[:space:]')"
  if [[ -z "${uid}" ]]; then
    aws_s3_die "cannot describe runtime SA ${email} (create it with make bootstrap-gcp first)"
  fi
  if [[ ! "${uid}" =~ ^[0-9]{1,64}$ ]]; then
    aws_s3_die "runtime SA ${email} uniqueId is not numeric"
  fi
  AWS_S3_GOOGLE_SUB="${uid}"
  export AWS_S3_GOOGLE_SUB
}

# AWS maps Google azp→accounts.google.com:aud, aud→oaud, sub→sub when azp present.
# Pin aud+sub to the runtime SA unique ID; pin oaud to AWS_S3_AUDIENCE.
aws_s3_render_trust_policy() {
  local sub="$1" audience="$2"
  jq -n \
    --arg provider "${AWS_S3_GOOGLE_PROVIDER}" \
    --arg sub "${sub}" \
    --arg audience "${audience}" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Principal: {Federated: $provider},
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {StringEquals: {
          ($provider + ":aud"): $sub,
          ($provider + ":oaud"): $audience,
          ($provider + ":sub"): $sub
        }}
      }]
    }'
}

aws_s3_object_arn() {
  printf 'arn:aws:s3:::%s/%s*' "$1" "${AWS_S3_PREFIX}"
}

aws_s3_render_permissions_policy() {
  local bucket="$1"
  jq -n --arg resource "$(aws_s3_object_arn "${bucket}")" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Action: "s3:PutObject",
        Resource: $resource
      }]
    }'
}

aws_s3_iam_tags_json() {
  jq -cn \
    --arg p "${AWS_S3_TAG_PROJECT}" --arg e "${AWS_S3_TAG_EXPERIMENT}" --arg u "${AWS_S3_TAG_PURPOSE}" \
    '[{Key: "Project", Value: $p}, {Key: "Experiment", Value: $e}, {Key: "Purpose", Value: $u}]'
}

aws_s3_canonical_policy() {
  jq -S '
    def arr: if type == "array" then sort else [.] end;
    .Statement |= (
      (if type == "array" then . else [.] end)
      | map(
          (if has("Action") then .Action |= arr else . end)
          | (if has("Resource") then .Resource |= arr else . end)
          | (if (.Principal | type) == "object" then .Principal |= map_values(arr) else . end)
          | (if has("Condition") then .Condition |= map_values(map_values(arr)) else . end)
        )
      | sort_by(tojson)
    )'
}

aws_s3_tags_ok() {
  jq -e \
    --arg p "${AWS_S3_TAG_PROJECT}" --arg e "${AWS_S3_TAG_EXPERIMENT}" --arg u "${AWS_S3_TAG_PURPOSE}" \
    '(map({(.Key): .Value}) | add // {}) as $t
     | $t.Project == $p and $t.Experiment == $e and $t.Purpose == $u' >/dev/null
}

aws_s3_require_aws_cli() {
  require_cmd aws
  require_cmd jq
  aws --version >/dev/null 2>&1 ||
    aws_s3_die "aws CLI is on PATH but does not run ($(command -v aws)); reinstall AWS CLI v2"
}

aws_s3_caller_identity() {
  local ident
  ident="$(aws sts get-caller-identity --output json)" ||
    aws_s3_die "cannot establish AWS caller identity (aws sts get-caller-identity failed)"
  AWS_S3_ACCOUNT="$(jq -r '.Account // empty' <<<"${ident}")"
  AWS_S3_CALLER_ARN="$(jq -r '.Arn // empty' <<<"${ident}")"
  [[ "${AWS_S3_ACCOUNT}" =~ ^[0-9]{12}$ ]] || aws_s3_die "caller identity returned no valid account ID"
  [[ -n "${AWS_S3_CALLER_ARN}" ]] || aws_s3_die "caller identity returned no ARN"
}

# Writes get-role JSON to $2; prints: present | absent | error
aws_s3_role_state() {
  local role="$1" out="$2" err
  err="$(aws_s3_mktemp get-role)"
  if aws iam get-role --role-name "${role}" --output json >"${out}" 2>"${err}"; then
    echo present
  elif grep -q 'NoSuchEntity' "${err}"; then
    echo absent
  else
    cat "${err}" >&2
    echo error
  fi
}

aws_s3_role_tags() {
  aws iam list-role-tags --role-name "$1" --output json | jq -c '.Tags // []'
}

aws_s3_role_inline_policy_names() {
  aws iam list-role-policies --role-name "$1" --output json | jq -c '.PolicyNames // []'
}

aws_s3_role_attached_policy_arns() {
  aws iam list-attached-role-policies --role-name "$1" --output json |
    jq -c '[.AttachedPolicies[]?.PolicyArn]'
}
