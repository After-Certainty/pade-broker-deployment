#!/usr/bin/env bash
# Render policy/bindings YAML from templates + .env. Never writes secret values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_project
load_versions

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

is_placeholder() {
  local v="$1"
  [[ -z "${v}" ]] && return 0
  [[ "${v}" == *YOUR_* ]] && return 0
  [[ "${v}" == your-* ]] && return 0
  [[ "${v}" == "owner/repo" ]] && return 0
  [[ "${v}" == "properties/123456789" ]] && return 0
  return 1
}

if [[ -z "${BROKER_URL:-}" ]]; then
  BROKER_URL="$(broker_url)"
fi
export BROKER_URL

# Subjects: CURSOR_OIDC_SUBJECTS (comma-separated) wins; else CURSOR_OIDC_SUBJECT.
SUBJECTS=()
if [[ -n "${CURSOR_OIDC_SUBJECTS:-}" ]]; then
  IFS=',' read -r -a _subjects <<< "${CURSOR_OIDC_SUBJECTS}"
  for s in "${_subjects[@]}"; do
    s="$(trim "${s}")"
    [[ -z "${s}" ]] && continue
    if is_placeholder "${s}"; then
      echo "error: CURSOR_OIDC_SUBJECTS contains a placeholder value: ${s}" >&2
      exit 1
    fi
    SUBJECTS+=("${s}")
  done
elif ! is_placeholder "${CURSOR_OIDC_SUBJECT:-}"; then
  SUBJECTS+=("${CURSOR_OIDC_SUBJECT}")
fi

GCE_SUBJECT=""
if ! is_placeholder "${GCE_OIDC_SUBJECT:-}"; then
  GCE_SUBJECT="$(trim "${GCE_OIDC_SUBJECT}")"
fi

missing=()
for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_REPOSITORIES GA_PROPERTY_ID \
  AWS_S3_ROLE_ARN AWS_S3_BUCKET AWS_S3_REGION AWS_S3_AUDIENCE; do
  if is_placeholder "${!v:-}"; then
    missing+=("${v}")
  fi
done
if ((${#SUBJECTS[@]} == 0)); then
  missing+=("CURSOR_OIDC_SUBJECT or CURSOR_OIDC_SUBJECTS")
fi
if [[ -z "${GCE_SUBJECT}" ]]; then
  missing+=("GCE_OIDC_SUBJECT")
fi

if ((${#missing[@]} > 0)); then
  echo "error: set the following in .env (see .env.example):" >&2
  for v in "${missing[@]}"; do
    echo "  ${v}" >&2
  done
  echo "hint: Cursor subjects come from: pade identity --audience ${BROKER_URL}" >&2
  echo "hint: GCE_OIDC_SUBJECT is the Google OIDC sub for the GCE-attached service account" >&2
  echo "hint: AWS_S3_* identifiers come from make bootstrap-aws-s3 / docs/experiment-007-phase-3.md" >&2
  exit 1
fi

# Fail closed on credential-shaped values in non-secret AWS config.
if [[ "${AWS_S3_ROLE_ARN}" != arn:aws:iam::*:role/* ]]; then
  echo "error: AWS_S3_ROLE_ARN must be an IAM role ARN (arn:aws:iam::<account>:role/<name>)" >&2
  exit 1
fi
case "${AWS_S3_ROLE_ARN}" in
  *AKIA*|*ASIA*|*aws_access_key*|*AWS_SECRET*)
    echo "error: AWS_S3_ROLE_ARN looks like credential material; refusing to render" >&2
    exit 1
    ;;
esac

GITHUB_REPOSITORIES_YAML=""
IFS=',' read -r -a _repos <<< "${GITHUB_REPOSITORIES}"
for repo in "${_repos[@]}"; do
  repo="$(trim "${repo}")"
  [[ -z "${repo}" ]] && continue
  GITHUB_REPOSITORIES_YAML+="          - ${repo}"$'\n'
done
if [[ -z "${GITHUB_REPOSITORIES_YAML}" ]]; then
  echo "error: GITHUB_REPOSITORIES must list at least one owner/repo" >&2
  exit 1
fi
GITHUB_REPOSITORIES_YAML="${GITHUB_REPOSITORIES_YAML%$'\n'}"

# Combined multi-issuer policies: Cursor rules (full caps) + least-priv GCE rule.
OIDC_POLICIES_YAML=""
for subject in "${SUBJECTS[@]}"; do
  OIDC_POLICIES_YAML+="  - issuer: cursor"$'\n'
  OIDC_POLICIES_YAML+="    subject: \"${subject}\""$'\n'
  OIDC_POLICIES_YAML+="    requireRepoURLs: false"$'\n'
  OIDC_POLICIES_YAML+="    capabilities:"$'\n'
  OIDC_POLICIES_YAML+="      - github.repo.read"$'\n'
  OIDC_POLICIES_YAML+="      - google-analytics.read"$'\n'
  OIDC_POLICIES_YAML+="      - vercel.diagnostics"$'\n'
done
OIDC_POLICIES_YAML+="  - issuer: google"$'\n'
OIDC_POLICIES_YAML+="    subject: \"${GCE_SUBJECT}\""$'\n'
OIDC_POLICIES_YAML+="    requireRepoURLs: false"$'\n'
OIDC_POLICIES_YAML+="    capabilities:"$'\n'
OIDC_POLICIES_YAML+="      - github.repo.read"$'\n'
OIDC_POLICIES_YAML+="      - aws.s3.bucket.write"
# No trailing newline trim — last line has no trailing \n by construction.
# Cursor subjects intentionally omit aws.s3.bucket.write (Experiment 007 Phase 3).

OUT_DIR="${ROOT}/config/.generated"
mkdir -p "${OUT_DIR}"

render_template() {
  local tmpl="$1"
  local dest="$2"
  local content
  content="$(<"${tmpl}")"
  content="${content//\$\{BROKER_URL\}/${BROKER_URL}}"
  content="${content//\$\{OIDC_POLICIES_YAML\}/${OIDC_POLICIES_YAML}}"
  content="${content//\$\{GITHUB_APP_ID\}/${GITHUB_APP_ID}}"
  content="${content//\$\{GITHUB_APP_INSTALLATION_ID\}/${GITHUB_APP_INSTALLATION_ID}}"
  content="${content//\$\{GA_PROPERTY_ID\}/${GA_PROPERTY_ID}}"
  content="${content//\$\{GITHUB_REPOSITORIES_YAML\}/${GITHUB_REPOSITORIES_YAML}}"
  content="${content//\$\{PROJECT_NUMBER\}/${PROJECT_NUMBER}}"
  content="${content//\$\{CURSOR_WIF_POOL_ID\}/${CURSOR_WIF_POOL_ID}}"
  content="${content//\$\{CURSOR_WIF_PROVIDER_ID\}/${CURSOR_WIF_PROVIDER_ID}}"
  content="${content//\$\{VERCEL_SUBJECT_SECRET_PREFIX\}/${VERCEL_SUBJECT_SECRET_PREFIX}}"
  content="${content//\$\{AWS_S3_ROLE_ARN\}/${AWS_S3_ROLE_ARN}}"
  content="${content//\$\{AWS_S3_REGION\}/${AWS_S3_REGION}}"
  content="${content//\$\{AWS_S3_BUCKET\}/${AWS_S3_BUCKET}}"
  content="${content//\$\{AWS_S3_AUDIENCE\}/${AWS_S3_AUDIENCE}}"
  cat > "${dest}" <<EOF
# Generated by make render-config — do not edit.
# Source: $(basename "${tmpl}") + .env
${content}
EOF
}

render_template "${ROOT}/config/broker-policy.yaml.tmpl" "$(policy_file)"
render_template "${ROOT}/config/broker-bindings.yaml.tmpl" "$(bindings_file)"

echo "==> Rendered $(policy_file_rel)"
echo "==> Rendered $(bindings_file_rel)"
echo "    audience=${BROKER_URL}"
echo "    cursor_subjects=${SUBJECTS[*]}"
echo "    gce_subject=${GCE_SUBJECT}"
