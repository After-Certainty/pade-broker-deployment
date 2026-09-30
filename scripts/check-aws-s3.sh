#!/usr/bin/env bash
# Experiment 007 Phase 3 AWS preflight (read-only).
# Resolves Cloud Run runtime SA unique ID via gcloud; never mutates AWS.
# Not for GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/aws-s3-lib.sh"

aws_s3_init_tmp
aws_s3_load_config
aws_s3_require_aws_cli
require_cmd gcloud

region="$(aws_s3_resolve_region)"
export AWS_REGION="${region}" AWS_DEFAULT_REGION="${region}" AWS_S3_REGION="${region}"

aws_s3_caller_identity
aws_s3_derive_runtime_unique_id

show() { printf '%-28s %s\n' "$1" "${2:-<unset>}"; }

printf 'Experiment 007 Phase 3 AWS check (read-only)\n\n'
show "aws_account" "${AWS_S3_ACCOUNT}"
show "caller_arn" "${AWS_S3_CALLER_ARN}"
show "region" "${region}"
show "bucket" "${AWS_S3_BUCKET}"
show "role_name" "${AWS_S3_ROLE_NAME}"
show "phase2_role_untouched" "${AWS_S3_PHASE2_ROLE_NAME}"
show "runtime_sa" "${AWS_S3_RUNTIME_SA_EMAIL}"
show "runtime_sa_unique_id" "${AWS_S3_GOOGLE_SUB}"
show "audience_oaud" "${AWS_S3_AUDIENCE}"
show "s3_scope" "s3://${AWS_S3_BUCKET}/${AWS_S3_PREFIX}* (PutObject only)"

printf '\n## Configuration\n'
config_ok=yes
if ! problems="$(aws_s3_validate_bootstrap_inputs)"; then
  config_ok=no
  while IFS= read -r line; do
    printf 'warning: %s\n' "${line}"
  done <<<"${problems}"
fi
show "bootstrap_inputs_ok" "${config_ok}"

trust_file="$(aws_s3_mktemp trust)"
perms_file="$(aws_s3_mktemp perms)"
aws_s3_render_trust_policy "${AWS_S3_GOOGLE_SUB}" "${AWS_S3_AUDIENCE}" >"${trust_file}"
aws_s3_render_permissions_policy "${AWS_S3_BUCKET}" >"${perms_file}"

printf '\n## Expected trust (accounts.google.com:aud←azp, oaud←aud, sub←sub)\n'
jq . "${trust_file}"

printf '\n## Expected permissions\n'
jq . "${perms_file}"

printf '\n## Existing Phase 3 role\n'
role_json="$(aws_s3_mktemp role)"
case "$(aws_s3_role_state "${AWS_S3_ROLE_NAME}" "${role_json}")" in
  present)
    show "role_exists" "yes ($(jq -r '.Role.Arn' "${role_json}"))"
    if aws_s3_role_tags "${AWS_S3_ROLE_NAME}" | aws_s3_tags_ok; then
      show "role_tags_ok" "yes"
    else
      show "role_tags_ok" "no"
    fi
    actual="$(jq '.Role.AssumeRolePolicyDocument' "${role_json}" | aws_s3_canonical_policy)"
    wanted="$(aws_s3_canonical_policy <"${trust_file}")"
    if [[ "${actual}" == "${wanted}" ]]; then
      show "trust_policy_matches" "yes"
    else
      show "trust_policy_matches" "no"
    fi
    if aws iam get-role-policy --role-name "${AWS_S3_ROLE_NAME}" \
      --policy-name "${AWS_S3_POLICY_NAME}" --output json >/dev/null 2>&1; then
      show "inline_policy_exists" "yes (${AWS_S3_POLICY_NAME})"
    else
      show "inline_policy_exists" "no (${AWS_S3_POLICY_NAME})"
    fi
    ;;
  absent)
    show "role_exists" "no"
    ;;
  *)
    show "role_exists" "unknown (get-role failed)"
    ;;
esac

printf '\nNo AWS resources were modified.\n'
printf 'Phase 2 role %s is intentionally not inspected for mutation.\n' "${AWS_S3_PHASE2_ROLE_NAME}"
