#!/usr/bin/env bash
# Show Experiment 007 Phase 3 AWS role configuration (read-only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/aws-s3-lib.sh"

aws_s3_init_tmp
aws_s3_load_config
aws_s3_require_aws_cli
require_cmd gcloud

region="$(aws_s3_resolve_region)"
export AWS_REGION="${region}" AWS_DEFAULT_REGION="${region}"

aws_s3_caller_identity
aws_s3_derive_runtime_unique_id

role="${AWS_S3_ROLE_NAME}"
role_file="$(aws_s3_mktemp role)"
role_state="$(aws_s3_role_state "${role}" "${role_file}")"

printf 'Experiment 007 Phase 3 AWS show\n\n'
printf 'account:              %s\n' "${AWS_S3_ACCOUNT}"
printf 'region:               %s\n' "${region}"
printf 'runtime_sa:           %s\n' "${AWS_S3_RUNTIME_SA_EMAIL}"
printf 'runtime_unique_id:    %s\n' "${AWS_S3_GOOGLE_SUB}"
printf 'audience:             %s\n' "${AWS_S3_AUDIENCE}"
printf 'bucket:               %s\n' "${AWS_S3_BUCKET}"
printf 'prefix:               %s\n' "${AWS_S3_PREFIX}"
printf 'role_name:            %s\n' "${role}"
printf 'phase2_role:          %s (untouched)\n' "${AWS_S3_PHASE2_ROLE_NAME}"

case "${role_state}" in
  absent)
    printf '\nrole_exists: no\n'
    printf 'Set AWS_S3_ROLE_ARN after: make bootstrap-aws-s3\n'
    exit 0
    ;;
  present)
    role_arn="$(jq -r '.Role.Arn' "${role_file}")"
    printf '\nrole_arn:             %s\n' "${role_arn}"
    printf '\n## Tags\n'
    aws_s3_role_tags "${role}" | jq .
    printf '\n## Trust policy\n'
    jq '.Role.AssumeRolePolicyDocument' "${role_file}" | jq .
    printf '\n## Inline policies\n'
    aws_s3_role_inline_policy_names "${role}" | jq .
    if aws iam get-role-policy --role-name "${role}" --policy-name "${AWS_S3_POLICY_NAME}" --output json >/dev/null 2>&1; then
      printf '\n## Inline policy %s\n' "${AWS_S3_POLICY_NAME}"
      aws iam get-role-policy --role-name "${role}" --policy-name "${AWS_S3_POLICY_NAME}" --output json |
        jq '.PolicyDocument'
    fi
    printf '\n## Attached managed policies\n'
    aws_s3_role_attached_policy_arns "${role}" | jq .
    printf '\nGitHub Environment variable to set:\n'
    printf '  AWS_S3_ROLE_ARN=%s\n' "${role_arn}"
    ;;
  *)
    aws_s3_die "cannot determine state of role ${role}"
    ;;
esac
