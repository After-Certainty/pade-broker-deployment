#!/usr/bin/env bash
# Contract test: GitHub Actions production .env writer ↔ render-config.sh subject semantics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

TMP=""
WORK=""

cleanup() {
  if [[ -n "${TMP:-}" && -d "${TMP}" ]]; then
    rm -rf "${TMP}"
  fi
  if [[ -n "${WORK:-}" && -d "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

TMP="$(mktemp -d)"
WORK="${TMP}/work"
mkdir -p "${WORK}/scripts" "${WORK}/config/.generated"

cp "${ROOT}/scripts/lib.sh" "${WORK}/scripts/"
cp "${ROOT}/scripts/render-config.sh" "${WORK}/scripts/"
cp "${ROOT}/scripts/write-production-env.sh" "${WORK}/scripts/"
cp "${ROOT}/versions.env" "${WORK}/"
cp "${ROOT}/config/broker-policy.yaml.tmpl" "${WORK}/config/"
cp "${ROOT}/config/broker-bindings.yaml.tmpl" "${WORK}/config/"

chmod +x "${WORK}/scripts/write-production-env.sh" "${WORK}/scripts/render-config.sh"

fixture_env=(
  PROJECT_ID=pade-ci-fixture
  PROJECT_NUMBER=123456789012
  GITHUB_APP_ID=100001
  GITHUB_APP_INSTALLATION_ID=200002
  GITHUB_REPOSITORIES=ci-fixture/pade-broker-deployment
  GA_PROPERTY_ID=properties/987654321
)

policy_path() {
  echo "${WORK}/config/.generated/broker-policy.yaml"
}

count_policy_subjects() {
  grep -c '^  - subject:' "$(policy_path)" || true
}

policy_contains_subject() {
  local subject="$1"
  grep -Fq "  - subject: \"${subject}\"" "$(policy_path)"
}

policy_lacks_subject() {
  local subject="$1"
  ! policy_contains_subject "${subject}"
}

run_writer_and_render() {
  local extra=("$@")
  (
    cd "${WORK}"
    export "${fixture_env[@]}"
    local kv
    for kv in "${extra[@]}"; do
      export "${kv?}"
    done
    ./scripts/write-production-env.sh
    ./scripts/render-config.sh
  )
}

assert_eq() {
  local got="$1"
  local want="$2"
  local msg="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${msg} (got=${got}, want=${want})" >&2
    exit 1
  fi
}

echo "==> case A: singular-only configuration"
run_writer_and_render CURSOR_OIDC_SUBJECT=user:singular
assert_eq "$(count_policy_subjects)" "1" "singular-only subject count"
policy_contains_subject "user:singular" || {
  echo "FAIL: policy missing user:singular" >&2
  exit 1
}

echo "==> case B: plural-only configuration"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render CURSOR_OIDC_SUBJECTS=user:alpha,user:beta
assert_eq "$(count_policy_subjects)" "2" "plural-only subject count"
policy_contains_subject "user:alpha" || {
  echo "FAIL: policy missing user:alpha" >&2
  exit 1
}
policy_contains_subject "user:beta" || {
  echo "FAIL: policy missing user:beta" >&2
  exit 1
}

echo "==> case C: plural wins when both are set"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  CURSOR_OIDC_SUBJECT=user:ignored-singular
assert_eq "$(count_policy_subjects)" "2" "both-set subject count"
policy_contains_subject "user:alpha" || {
  echo "FAIL: policy missing user:alpha" >&2
  exit 1
}
policy_contains_subject "user:beta" || {
  echo "FAIL: policy missing user:beta" >&2
  exit 1
}
policy_lacks_subject "user:ignored-singular" || {
  echo "FAIL: singular subject should be ignored when plural is set" >&2
  exit 1
}

echo "==> case D: neither subject variable supplied"
rm -f "${WORK}/.env"
set +e
(
  cd "${WORK}"
  export "${fixture_env[@]}"
  unset CURSOR_OIDC_SUBJECT CURSOR_OIDC_SUBJECTS
  ./scripts/write-production-env.sh
) >"${TMP}/case-d.out" 2>&1
rc=$?
set -e
assert_eq "${rc}" "1" "writer should fail when no subject vars are set"
grep -Fq 'CURSOR_OIDC_SUBJECTS or CURSOR_OIDC_SUBJECT' "${TMP}/case-d.out" || {
  echo "FAIL: case D error message missing subject variable names" >&2
  cat "${TMP}/case-d.out" >&2
  exit 1
}

echo "OK: subject config contract tests passed"
