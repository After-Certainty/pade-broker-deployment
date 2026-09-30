#!/usr/bin/env bash
# Create or reconcile Experiment 007 Phase 3 IAM role for broker AWS S3 fulfillment.
#
# Trusts ONLY the Cloud Run runtime service account (unique ID via gcloud).
# Grants only s3:PutObject on <bucket>/experiment-007/*.
# Creates no access keys. Does not touch Phase 2 role or the S3 bucket.
#
# Workstation only (gcloud + aws). Never run from GitHub Actions.
#
# Usage: bootstrap-aws-s3.sh [--yes]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/aws-s3-lib.sh"

assume_yes=no
for arg in "$@"; do
  case "${arg}" in
    --yes) assume_yes=yes ;;
    *) aws_s3_die "unknown argument: ${arg}" ;;
  esac
done

aws_s3_init_tmp
aws_s3_load_config
aws_s3_require_aws_cli
require_cmd gcloud

region="$(aws_s3_resolve_region)"
export AWS_REGION="${region}" AWS_DEFAULT_REGION="${region}" AWS_S3_REGION="${region}"

aws_s3_caller_identity
aws_s3_derive_runtime_unique_id

if ! problems="$(aws_s3_validate_bootstrap_inputs)"; then
  printf '%s\n' "${problems}" >&2
  aws_s3_die "refusing to bootstrap without a complete, safe trust configuration"
fi

role="${AWS_S3_ROLE_NAME}"
bucket="${AWS_S3_BUCKET}"
account="${AWS_S3_ACCOUNT}"

trust_file="$(aws_s3_mktemp trust-policy)"
perms_file="$(aws_s3_mktemp permissions-policy)"
aws_s3_render_trust_policy "${AWS_S3_GOOGLE_SUB}" "${AWS_S3_AUDIENCE}" >"${trust_file}"
aws_s3_render_permissions_policy "${bucket}" >"${perms_file}"

cat <<EOF
Experiment 007 Phase 3 AWS bootstrap plan

AWS account:           ${account}
caller:                ${AWS_S3_CALLER_ARN}
region:                ${region}
bucket (unchanged):    ${bucket}
role:                  ${role}
inline policy:         ${AWS_S3_POLICY_NAME}
S3 scope:              s3://${bucket}/${AWS_S3_PREFIX}* (s3:PutObject only)
runtime SA:            ${AWS_S3_RUNTIME_SA_EMAIL}
runtime unique ID:     ${AWS_S3_GOOGLE_SUB}
audience (oaud):       ${AWS_S3_AUDIENCE}
tags:                  Project=${AWS_S3_TAG_PROJECT} Experiment=${AWS_S3_TAG_EXPERIMENT} Purpose=${AWS_S3_TAG_PURPOSE}
phase2 role (untouched): ${AWS_S3_PHASE2_ROLE_NAME}

Trust policy (aud←azp, oaud←aud, sub←sub):
$(jq . "${trust_file}")

Permissions policy:
$(jq . "${perms_file}")

EOF

if [[ "${assume_yes}" != yes ]]; then
  [[ -t 0 ]] || aws_s3_die "not a terminal; re-run interactively or pass --yes"
  printf 'Proceed? [y/N] ' >&2
  IFS= read -r answer || answer=""
  [[ "${answer}" == y || "${answer}" == Y ]] || aws_s3_die "aborted; nothing changed"
fi

role_file="$(aws_s3_mktemp role)"
role_state="$(aws_s3_role_state "${role}" "${role_file}")"
case "${role_state}" in
  absent)
    aws_s3_log "role: creating ${role}"
    aws iam create-role \
      --role-name "${role}" \
      --assume-role-policy-document "file://${trust_file}" \
      --description "pade-broker Experiment 007 Phase 3: Cloud Run runtime web identity -> s3:PutObject on ${bucket}/${AWS_S3_PREFIX}*" \
      --max-session-duration 3600 \
      --tags "$(aws_s3_iam_tags_json)" >/dev/null
    aws iam wait role-exists --role-name "${role}"
    ;;
  present)
    aws_s3_role_tags "${role}" | aws_s3_tags_ok ||
      aws_s3_die "role ${role} exists but is not tagged as Experiment 007 Phase 3; refusing to adopt it"
    actual="$(jq '.Role.AssumeRolePolicyDocument' "${role_file}" | aws_s3_canonical_policy)"
    wanted="$(aws_s3_canonical_policy <"${trust_file}")"
    if [[ "${actual}" != "${wanted}" ]]; then
      aws_s3_log "role ${role} has a different trust policy:"
      diff -u <(printf '%s\n' "${wanted}") <(printf '%s\n' "${actual}") >&2 || true
      aws_s3_die "refusing to rewrite an existing trust relationship; run make teardown-aws-s3 and bootstrap again if the change is intended"
    fi
    aws_s3_log "role: exists, tagged, trust policy matches"
    ;;
  *)
    aws_s3_die "cannot determine state of role ${role} (get-role failed)"
    ;;
esac

attached="$(aws_s3_role_attached_policy_arns "${role}")"
[[ "$(jq 'length' <<<"${attached}")" == 0 ]] ||
  aws_s3_die "role ${role} has attached managed policies ${attached}; refusing to continue"
inline_names="$(aws_s3_role_inline_policy_names "${role}")"
jq -e --arg p "${AWS_S3_POLICY_NAME}" 'all(.[]; . == $p)' <<<"${inline_names}" >/dev/null ||
  aws_s3_die "role ${role} has unexpected inline policies ${inline_names}; refusing to continue"

aws iam put-role-policy \
  --role-name "${role}" \
  --policy-name "${AWS_S3_POLICY_NAME}" \
  --policy-document "file://${perms_file}"
aws_s3_log "role: inline policy ${AWS_S3_POLICY_NAME} applied"

actual="$(aws iam get-role-policy --role-name "${role}" --policy-name "${AWS_S3_POLICY_NAME}" --output json |
  jq '.PolicyDocument' | aws_s3_canonical_policy)"
[[ "${actual}" == "$(aws_s3_canonical_policy <"${perms_file}")" ]] ||
  aws_s3_die "inline policy read back does not match the rendered policy"

actual="$(aws iam get-role --role-name "${role}" --output json |
  jq '.Role.AssumeRolePolicyDocument' | aws_s3_canonical_policy)"
[[ "${actual}" == "$(aws_s3_canonical_policy <"${trust_file}")" ]] ||
  aws_s3_die "trust policy read back does not match the rendered policy"

role_arn="$(aws iam get-role --role-name "${role}" --query 'Role.Arn' --output text)"

cat <<EOF

Experiment 007 Phase 3 AWS bootstrap complete.

role ARN:  ${role_arn}
scope:     s3:PutObject on arn:aws:s3:::${bucket}/${AWS_S3_PREFIX}*
audience:  ${AWS_S3_AUDIENCE}

No access keys were created. No web-identity exchange was performed.
Bucket and Phase 2 role were not modified.

Next:
  1. Record AWS_S3_ROLE_ARN=${role_arn}
  2. Set GitHub Environment production variables (see docs/experiment-007-phase-3.md)
  3. make show-aws-s3
EOF
