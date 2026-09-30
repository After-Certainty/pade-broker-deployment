#!/usr/bin/env bash
# Tear down Experiment 007 Phase 3 IAM role only.
#
# Deletes only the Phase 3 role when it carries the expected tags and policies.
# Never deletes the Phase 2 role, the S3 bucket, or any objects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/aws-s3-lib.sh"

[[ $# -eq 0 ]] || aws_s3_die "teardown-aws-s3 takes no arguments"

aws_s3_init_tmp
aws_s3_load_config

if ! aws_s3_validate_role_name "${AWS_S3_ROLE_NAME}" >/dev/null; then
  aws_s3_validate_role_name "${AWS_S3_ROLE_NAME}" >&2 || true
  aws_s3_die "refusing to tear down without a valid Phase 3 role name"
fi

aws_s3_require_aws_cli

region="$(aws_s3_resolve_region)"
export AWS_REGION="${region}" AWS_DEFAULT_REGION="${region}"

aws_s3_caller_identity

role="${AWS_S3_ROLE_NAME}"
account="${AWS_S3_ACCOUNT}"
role_file="$(aws_s3_mktemp role)"
role_state="$(aws_s3_role_state "${role}" "${role_file}")"

case "${role_state}" in
  absent)
    printf 'role %s already absent; nothing to do\n' "${role}"
    exit 0
    ;;
  present)
    aws_s3_role_tags "${role}" | aws_s3_tags_ok ||
      aws_s3_die "role ${role} is not tagged as Experiment 007 Phase 3; refusing to touch it"
    role_arn="$(jq -r '.Role.Arn' "${role_file}")"
    [[ "${role_arn}" == "arn:aws:iam::${account}:role/"* ]] ||
      aws_s3_die "role ARN ${role_arn} is not in account ${account}"
    attached="$(aws_s3_role_attached_policy_arns "${role}")"
    [[ "$(jq 'length' <<<"${attached}")" == 0 ]] ||
      aws_s3_die "role ${role} has attached managed policies ${attached}; refusing to touch it"
    inline_names="$(aws_s3_role_inline_policy_names "${role}")"
    jq -e --arg p "${AWS_S3_POLICY_NAME}" 'all(.[]; . == $p)' <<<"${inline_names}" >/dev/null ||
      aws_s3_die "role ${role} has unexpected inline policies ${inline_names}; refusing to touch it"
    ;;
  *)
    aws_s3_die "cannot determine state of role ${role}"
    ;;
esac

printf 'Experiment 007 Phase 3 AWS teardown plan\n\n'
printf 'AWS account: %s\n' "${account}"
printf 'caller:      %s\n' "${AWS_S3_CALLER_ARN}"
printf 'delete role: %s\n' "${role_arn}"
printf 'bucket:      NOT deleted (%s)\n' "${AWS_S3_BUCKET}"
printf 'phase2 role: NOT deleted (%s)\n\n' "${AWS_S3_PHASE2_ROLE_NAME}"

[[ -t 0 ]] || aws_s3_die "confirmation requires an interactive terminal"
printf 'Type the role name to confirm deletion: ' >&2
IFS= read -r answer || aws_s3_die "no confirmation received"
[[ "${answer}" == "${role}" ]] || aws_s3_die "confirmation did not match; nothing changed"

inline_names="$(aws_s3_role_inline_policy_names "${role}")"
if jq -e --arg p "${AWS_S3_POLICY_NAME}" 'any(.[]; . == $p)' <<<"${inline_names}" >/dev/null; then
  aws iam delete-role-policy --role-name "${role}" --policy-name "${AWS_S3_POLICY_NAME}"
  aws_s3_log "deleted inline policy ${AWS_S3_POLICY_NAME}"
fi
aws iam delete-role --role-name "${role}"
aws_s3_log "deleted role ${role}"

printf '\nTeardown complete. Bucket and Phase 2 role were not modified.\n'
