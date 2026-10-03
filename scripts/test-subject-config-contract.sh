#!/usr/bin/env bash
# Contract test: GitHub Actions production .env writer ↔ render-config.sh
# multi-issuer subject semantics (Cursor + GCE).
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

FIXTURE_GCE_SUBJECT="999000111222333444555"

FIXTURE_AWS_ROLE_ARN="arn:aws:iam::111122223333:role/pade-broker-experiment-007-s3-write"

fixture_env=(
  PROJECT_ID=pade-ci-fixture
  PROJECT_NUMBER=123456789012
  GITHUB_APP_ID=100001
  GITHUB_APP_INSTALLATION_ID=200002
  GITHUB_REPOSITORIES=ci-fixture/pade-broker-deployment
  GA_PROPERTY_ID=properties/987654321
  GCE_OIDC_SUBJECT="${FIXTURE_GCE_SUBJECT}"
  AWS_S3_ROLE_ARN="${FIXTURE_AWS_ROLE_ARN}"
  AWS_S3_BUCKET=ci-fixture-007
  AWS_S3_REGION=us-east-1
  AWS_S3_AUDIENCE=https://ci.example.invalid/pade-aws-s3
)

policy_path() {
  echo "${WORK}/config/.generated/broker-policy.yaml"
}

count_policy_rules() {
  grep -cE '^  - issuer: (cursor|google)$' "$(policy_path)" || true
}

count_cursor_rules() {
  grep -cE '^  - issuer: cursor$' "$(policy_path)" || true
}

count_google_rules() {
  grep -cE '^  - issuer: google$' "$(policy_path)" || true
}

policy_contains_subject() {
  local subject="$1"
  grep -Fq "    subject: \"${subject}\"" "$(policy_path)"
}

policy_lacks_subject() {
  local subject="$1"
  ! policy_contains_subject "${subject}"
}

# Extract the YAML block for one issuer+subject rule (until next rule or EOF).
rule_block_for() {
  local issuer="$1"
  local subject="$2"
  awk -v issuer="${issuer}" -v subject="${subject}" '
    /^  - issuer: / {
      if (collecting && matched) {
        printf "%s", block
        found = 1
        exit
      }
      collecting = ($0 == "  - issuer: " issuer)
      matched = 0
      block = ""
    }
    collecting {
      block = block $0 "\n"
      if ($0 == "    subject: \"" subject "\"") matched = 1
    }
    END {
      if (!found && collecting && matched) printf "%s", block
    }
  ' "$(policy_path)"
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

assert_file_contains() {
  local needle="$1"
  local msg="$2"
  if ! grep -Fq "${needle}" "$(policy_path)"; then
    echo "FAIL: ${msg}" >&2
    echo "  missing: ${needle}" >&2
    exit 1
  fi
}

assert_file_lacks() {
  local needle="$1"
  local msg="$2"
  if grep -Fq "${needle}" "$(policy_path)"; then
    echo "FAIL: ${msg}" >&2
    echo "  unexpectedly found: ${needle}" >&2
    exit 1
  fi
}

assert_multi_issuer_shape() {
  local policy
  policy="$(policy_path)"

  assert_file_contains "  issuers:" "policy must declare oidc.issuers"
  assert_file_contains "    cursor:" "policy must declare cursor issuer alias"
  assert_file_contains "    google:" "policy must declare google issuer alias"
  assert_file_contains "      issuer: https://api.cursor.com" "cursor issuer URL"
  assert_file_contains "      jwksURL: https://api.cursor.com/keys" "cursor JWKS URL"
  assert_file_contains "      issuer: https://accounts.google.com" "google issuer URL"
  assert_file_contains "      jwksURL: https://www.googleapis.com/oauth2/v3/certs" "google JWKS URL"

  local issuer_alias_count
  issuer_alias_count="$(grep -cE '^    (cursor|google):$' "${policy}" || true)"
  assert_eq "${issuer_alias_count}" "2" "exactly two OIDC issuer aliases"

  # No legacy top-level oidc.issuer / oidc.audience.
  if grep -E '^  issuer:' "${policy}" >/dev/null; then
    echo "FAIL: legacy top-level oidc.issuer must not remain" >&2
    exit 1
  fi
  if grep -E '^  audience:' "${policy}" >/dev/null; then
    echo "FAIL: legacy top-level oidc.audience must not remain" >&2
    exit 1
  fi

  local audience_count
  audience_count="$(grep -cE '^      audience: https://' "${policy}" || true)"
  assert_eq "${audience_count}" "2" "both issuers must set audience"

  assert_file_lacks "YOUR_" "no placeholder subjects may survive rendering"
}

assert_cursor_capabilities() {
  local subject="$1"
  local expect_sanity="${2:-no}"
  local expect_radgnarrack="${3:-no}"
  local block
  block="$(rule_block_for cursor "${subject}")"
  [[ -n "${block}" ]] || {
    echo "FAIL: no cursor rule block for ${subject}" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "issuer: cursor" || {
    echo "FAIL: cursor rule missing issuer for ${subject}" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "github.repo.read" || {
    echo "FAIL: cursor rule missing github.repo.read for ${subject}" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "google-analytics.read" || {
    echo "FAIL: cursor rule missing google-analytics.read for ${subject}" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "vercel.diagnostics" || {
    echo "FAIL: cursor rule missing vercel.diagnostics for ${subject}" >&2
    exit 1
  }
  if echo "${block}" | grep -Fq "aws.s3.bucket.write"; then
    echo "FAIL: Cursor rule must not include aws.s3.bucket.write" >&2
    exit 1
  fi
  if [[ "${expect_sanity}" == "yes" ]]; then
    echo "${block}" | grep -Fq "sanity.rehearsal.write" || {
      echo "FAIL: cursor rule missing sanity.rehearsal.write for ${subject}" >&2
      exit 1
    }
  else
    if echo "${block}" | grep -Fq "sanity.rehearsal.write"; then
      echo "FAIL: Cursor rule must not include sanity.rehearsal.write for ${subject} (not on Sanity allowlist)" >&2
      exit 1
    fi
  fi
  if [[ "${expect_radgnarrack}" == "yes" ]]; then
    echo "${block}" | grep -Fq "vercel.radgnarrack.read" || {
      echo "FAIL: cursor rule missing vercel.radgnarrack.read for ${subject}" >&2
      exit 1
    }
  else
    if echo "${block}" | grep -Fq "vercel.radgnarrack.read"; then
      echo "FAIL: Cursor rule must not include vercel.radgnarrack.read for ${subject} (not on RadGnaRack Vercel allowlist)" >&2
      exit 1
    fi
  fi
}

assert_gce_least_privilege() {
  local block
  block="$(rule_block_for google "${FIXTURE_GCE_SUBJECT}")"
  [[ -n "${block}" ]] || {
    echo "FAIL: no google rule block for GCE subject" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "issuer: google" || {
    echo "FAIL: GCE rule missing issuer: google" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "github.repo.read" || {
    echo "FAIL: GCE rule missing github.repo.read" >&2
    exit 1
  }
  echo "${block}" | grep -Fq "aws.s3.bucket.write" || {
    echo "FAIL: GCE rule missing aws.s3.bucket.write" >&2
    exit 1
  }
  if echo "${block}" | grep -Fq "google-analytics.read"; then
    echo "FAIL: GCE rule must not include google-analytics.read" >&2
    exit 1
  fi
  if echo "${block}" | grep -Fq "vercel.diagnostics"; then
    echo "FAIL: GCE rule must not include vercel.diagnostics" >&2
    exit 1
  fi
  if echo "${block}" | grep -Fq "vercel.radgnarrack.read"; then
    echo "FAIL: GCE rule must not include vercel.radgnarrack.read" >&2
    exit 1
  fi
  if echo "${block}" | grep -Fq "sanity.rehearsal.write"; then
    echo "FAIL: GCE rule must not include sanity.rehearsal.write" >&2
    exit 1
  fi
  local cap_count
  cap_count="$(echo "${block}" | grep -cE '^      - ' || true)"
  assert_eq "${cap_count}" "2" "GCE rule must have exactly two capabilities (github + aws.s3)"
}

assert_aws_s3_bindings() {
  local bindings="${WORK}/config/.generated/broker-bindings.yaml"
  [[ -f "${bindings}" ]] || {
    echo "FAIL: bindings file missing" >&2
    exit 1
  }
  grep -Fq 'aws.s3.bucket.write:' "${bindings}" || {
    echo "FAIL: bindings missing aws.s3.bucket.write" >&2
    exit 1
  }
  grep -Fq '/providers/pade-provider-aws-s3' "${bindings}" || {
    echo "FAIL: bindings missing aws-s3 provider path" >&2
    exit 1
  }
  grep -Fq "roleArn: \"${FIXTURE_AWS_ROLE_ARN}\"" "${bindings}" || {
    echo "FAIL: bindings missing fixture roleArn" >&2
    exit 1
  }
  grep -Fq 'bucket: "ci-fixture-007"' "${bindings}" || {
    echo "FAIL: bindings missing fixture bucket" >&2
    exit 1
  }
  grep -Fq 'audience: "https://ci.example.invalid/pade-aws-s3"' "${bindings}" || {
    echo "FAIL: bindings missing fixture audience" >&2
    exit 1
  }
  if grep -Eiq 'AKIA[0-9A-Z]{16}|aws_secret_access_key|AWS_SECRET_ACCESS_KEY|BEGIN (RSA )?PRIVATE KEY' "${bindings}"; then
    echo "FAIL: bindings appear to contain credential material" >&2
    exit 1
  fi
}

assert_sanity_bindings() {
  local bindings="${WORK}/config/.generated/broker-bindings.yaml"
  [[ -f "${bindings}" ]] || {
    echo "FAIL: bindings file missing" >&2
    exit 1
  }
  grep -Fq 'sanity.rehearsal.write:' "${bindings}" || {
    echo "FAIL: bindings missing sanity.rehearsal.write" >&2
    exit 1
  }
  grep -Fq '/providers/pade-provider-sanity' "${bindings}" || {
    echo "FAIL: bindings missing sanity provider path" >&2
    exit 1
  }
  grep -Fq 'fulfillment: subject-secret-wif' "${bindings}" || {
    echo "FAIL: bindings missing subject-secret-wif" >&2
    exit 1
  }
  grep -Fq 'tokenEnv: SANITY_API_TOKEN' "${bindings}" || {
    echo "FAIL: bindings missing SANITY_API_TOKEN tokenEnv" >&2
    exit 1
  }
  grep -Fq 'secretIdPrefix: "sanity-token-sub"' "${bindings}" || {
    echo "FAIL: bindings missing sanity-token-sub prefix" >&2
    exit 1
  }
  if grep -Eiq 'sk_[A-Za-z0-9]|SANITY_API_TOKEN:[[:space:]]*["'\'']?[a-zA-Z0-9]{20}' "${bindings}"; then
    echo "FAIL: bindings appear to contain Sanity credential material" >&2
    exit 1
  fi
  if grep -Eiq 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN (RSA )?PRIVATE KEY' "${bindings}"; then
    echo "FAIL: bindings appear to contain credential material" >&2
    exit 1
  fi
}

# Prove vercel.diagnostics and vercel.radgnarrack.read use distinct secret namespaces.
assert_vercel_secret_prefix_isolation() {
  local bindings="${WORK}/config/.generated/broker-bindings.yaml"
  [[ -f "${bindings}" ]] || {
    echo "FAIL: bindings file missing" >&2
    exit 1
  }
  grep -Fq 'vercel.diagnostics:' "${bindings}" || {
    echo "FAIL: bindings missing vercel.diagnostics" >&2
    exit 1
  }
  grep -Fq 'vercel.radgnarrack.read:' "${bindings}" || {
    echo "FAIL: bindings missing vercel.radgnarrack.read" >&2
    exit 1
  }
  # Extract secretIdPrefix under each capability block (until next top-level capability key).
  local diag_prefix rg_prefix
  diag_prefix="$(awk '
    /^  vercel\.diagnostics:/ {in_block=1; next}
    /^  [a-zA-Z0-9_.]+:/ {if (in_block) exit}
    in_block && /secretIdPrefix:/ {
      gsub(/[" ]/, "", $2); print $2; exit
    }
  ' "${bindings}")"
  rg_prefix="$(awk '
    /^  vercel\.radgnarrack\.read:/ {in_block=1; next}
    /^  [a-zA-Z0-9_.]+:/ {if (in_block) exit}
    in_block && /secretIdPrefix:/ {
      gsub(/[" ]/, "", $2); print $2; exit
    }
  ' "${bindings}")"
  assert_eq "${diag_prefix}" "vercel-token-sub" "vercel.diagnostics must use vercel-token-sub prefix"
  assert_eq "${rg_prefix}" "vercel-radgnarrack-token-sub" "vercel.radgnarrack.read must use vercel-radgnarrack-token-sub prefix"
  if [[ "${diag_prefix}" == "${rg_prefix}" ]]; then
    echo "FAIL: Vercel capability secret prefixes must not collapse to the same namespace" >&2
    exit 1
  fi
  # Both capabilities reuse the same provider binary.
  local vercel_provider_count
  vercel_provider_count="$(grep -cF '/providers/pade-provider-vercel' "${bindings}" || true)"
  assert_eq "${vercel_provider_count}" "2" "both Vercel capabilities must point at pade-provider-vercel"
}

run_writer_and_render() {
  local extra=("$@")
  (
    cd "${WORK}"
    unset CURSOR_OIDC_SUBJECT CURSOR_OIDC_SUBJECTS GCE_OIDC_SUBJECT \
      SANITY_CURSOR_OIDC_SUBJECTS RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS
    export "${fixture_env[@]}"
    local kv
    for kv in "${extra[@]}"; do
      export "${kv?}"
    done
    ./scripts/write-production-env.sh
    ./scripts/render-config.sh
  )
}

# Isolated fail-closed render (captures stdout+stderr). Avoids duplicating
# `export CURSOR_OIDC_SUBJECTS=…` across multiple (subshells), which would
# otherwise trip shellcheck warnings about subshell-local modifications.
run_fail_closed_render() {
  local outfile="$1"
  shift
  local extra=("$@")
  (
    cd "${WORK}"
    unset CURSOR_OIDC_SUBJECT CURSOR_OIDC_SUBJECTS GCE_OIDC_SUBJECT \
      SANITY_CURSOR_OIDC_SUBJECTS RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS
    export "${fixture_env[@]}"
    local kv
    for kv in "${extra[@]}"; do
      export "${kv?}"
    done
    ./scripts/write-production-env.sh
    ./scripts/render-config.sh
  ) >"${outfile}" 2>&1
}

echo "==> case A: singular-only Cursor configuration"
run_writer_and_render CURSOR_OIDC_SUBJECT=user:singular
assert_eq "$(count_cursor_rules)" "1" "singular-only cursor rule count"
assert_eq "$(count_google_rules)" "1" "singular-only google rule count"
assert_eq "$(count_policy_rules)" "2" "singular-only total rule count"
policy_contains_subject "user:singular" || {
  echo "FAIL: policy missing user:singular" >&2
  exit 1
}
policy_contains_subject "${FIXTURE_GCE_SUBJECT}" || {
  echo "FAIL: policy missing GCE subject" >&2
  exit 1
}
assert_cursor_capabilities "user:singular"
assert_gce_least_privilege
assert_multi_issuer_shape
assert_aws_s3_bindings
assert_sanity_bindings
assert_vercel_secret_prefix_isolation

echo "==> case B: plural-only Cursor configuration"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render CURSOR_OIDC_SUBJECTS=user:alpha,user:beta
assert_eq "$(count_cursor_rules)" "2" "plural-only cursor rule count"
assert_eq "$(count_google_rules)" "1" "plural-only google rule count"
assert_eq "$(count_policy_rules)" "3" "plural-only total rule count"
policy_contains_subject "user:alpha" || {
  echo "FAIL: policy missing user:alpha" >&2
  exit 1
}
policy_contains_subject "user:beta" || {
  echo "FAIL: policy missing user:beta" >&2
  exit 1
}
assert_cursor_capabilities "user:alpha"
assert_cursor_capabilities "user:beta"
assert_gce_least_privilege
assert_multi_issuer_shape
assert_sanity_bindings

echo "==> case C: plural wins when both Cursor vars are set"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  CURSOR_OIDC_SUBJECT=user:ignored-singular
assert_eq "$(count_cursor_rules)" "2" "both-set cursor rule count"
assert_eq "$(count_policy_rules)" "3" "both-set total rule count"
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
assert_cursor_capabilities "user:alpha"
assert_cursor_capabilities "user:beta"
assert_multi_issuer_shape

echo "==> case D: neither Cursor subject variable supplied"
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
assert_eq "${rc}" "1" "writer should fail when no Cursor subject vars are set"
grep -Fq 'CURSOR_OIDC_SUBJECTS or CURSOR_OIDC_SUBJECT' "${TMP}/case-d.out" || {
  echo "FAIL: case D error message missing subject variable names" >&2
  cat "${TMP}/case-d.out" >&2
  exit 1
}

echo "==> case E: missing GCE subject fails"
rm -f "${WORK}/.env"
set +e
(
  cd "${WORK}"
  export "${fixture_env[@]}"
  unset GCE_OIDC_SUBJECT
  CURSOR_OIDC_SUBJECT=user:singular ./scripts/write-production-env.sh
) >"${TMP}/case-e.out" 2>&1
rc=$?
set -e
assert_eq "${rc}" "1" "writer should fail when GCE_OIDC_SUBJECT is unset"
grep -Fq 'GCE_OIDC_SUBJECT' "${TMP}/case-e.out" || {
  echo "FAIL: case E error message missing GCE_OIDC_SUBJECT" >&2
  cat "${TMP}/case-e.out" >&2
  exit 1
}

echo "==> case E2: missing AWS_S3_ROLE_ARN fails"
rm -f "${WORK}/.env"
set +e
(
  cd "${WORK}"
  export "${fixture_env[@]}"
  unset AWS_S3_ROLE_ARN
  CURSOR_OIDC_SUBJECT=user:singular ./scripts/write-production-env.sh
) >"${TMP}/case-e2.out" 2>&1
rc=$?
set -e
assert_eq "${rc}" "1" "writer should fail when AWS_S3_ROLE_ARN is unset"
grep -Fq 'AWS_S3_ROLE_ARN' "${TMP}/case-e2.out" || {
  echo "FAIL: case E2 error message missing AWS_S3_ROLE_ARN" >&2
  cat "${TMP}/case-e2.out" >&2
  exit 1
}

echo "==> case F: GCE subject appears exactly once with least privilege"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render CURSOR_OIDC_SUBJECT=user:singular
gce_subject_count="$(grep -cF "    subject: \"${FIXTURE_GCE_SUBJECT}\"" "$(policy_path)" || true)"
assert_eq "${gce_subject_count}" "1" "GCE subject must appear exactly once"
assert_eq "$(count_google_rules)" "1" "exactly one google issuer rule"
assert_gce_least_privilege
assert_multi_issuer_shape

echo "==> case G: empty Sanity allowlist grants no Sanity capability"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render CURSOR_OIDC_SUBJECTS=user:alpha,user:beta
assert_cursor_capabilities "user:alpha" no
assert_cursor_capabilities "user:beta" no
assert_gce_least_privilege
assert_sanity_bindings
if grep -Fq "sanity.rehearsal.write" "$(policy_path)"; then
  echo "FAIL: empty Sanity allowlist must not put sanity.rehearsal.write in policy" >&2
  exit 1
fi

echo "==> case H: Sanity allowlist grants capability only to listed Cursor subjects"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  SANITY_CURSOR_OIDC_SUBJECTS=user:alpha
assert_cursor_capabilities "user:alpha" yes
assert_cursor_capabilities "user:beta" no
assert_gce_least_privilege
assert_sanity_bindings
grep -Fq "SANITY_CURSOR_OIDC_SUBJECTS=user:alpha" "${WORK}/.env" || {
  echo "FAIL: production env writer must pass through SANITY_CURSOR_OIDC_SUBJECTS" >&2
  exit 1
}

echo "==> case I: Sanity subject not in Cursor allowlist fails configuration"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
set +e
run_fail_closed_render "${TMP}/case-i.out" \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  SANITY_CURSOR_OIDC_SUBJECTS=user:unknown
rc=$?
set -e
assert_eq "${rc}" "1" "render should fail when Sanity subject is not in Cursor allowlist"
grep -Fq 'SANITY_CURSOR_OIDC_SUBJECTS' "${TMP}/case-i.out" || {
  echo "FAIL: case I error message missing SANITY_CURSOR_OIDC_SUBJECTS" >&2
  cat "${TMP}/case-i.out" >&2
  exit 1
}
grep -Fq 'not in CURSOR_OIDC_SUBJECT' "${TMP}/case-i.out" || {
  echo "FAIL: case I error message missing subset check hint" >&2
  cat "${TMP}/case-i.out" >&2
  exit 1
}

echo "==> case J: empty RadGnaRack Vercel allowlist grants nobody vercel.radgnarrack.read"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render CURSOR_OIDC_SUBJECTS=user:alpha,user:beta
assert_cursor_capabilities "user:alpha" no no
assert_cursor_capabilities "user:beta" no no
assert_gce_least_privilege
assert_vercel_secret_prefix_isolation
if grep -Fq "vercel.radgnarrack.read" "$(policy_path)"; then
  echo "FAIL: empty RadGnaRack allowlist must not put vercel.radgnarrack.read in policy" >&2
  exit 1
fi

echo "==> case K: RadGnaRack Vercel allowlist grants capability only to listed Cursor subjects"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS=user:alpha
assert_cursor_capabilities "user:alpha" no yes
assert_cursor_capabilities "user:beta" no no
assert_gce_least_privilege
assert_vercel_secret_prefix_isolation
grep -Fq "RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS=user:alpha" "${WORK}/.env" || {
  echo "FAIL: production env writer must pass through RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS" >&2
  exit 1
}

echo "==> case L: RadGnaRack subject not in Cursor allowlist fails configuration"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
set +e
run_fail_closed_render "${TMP}/case-l.out" \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS=user:unknown
rc=$?
set -e
assert_eq "${rc}" "1" "render should fail when RadGnaRack subject is not in Cursor allowlist"
grep -Fq 'RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS' "${TMP}/case-l.out" || {
  echo "FAIL: case L error message missing RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS" >&2
  cat "${TMP}/case-l.out" >&2
  exit 1
}
grep -Fq 'not in CURSOR_OIDC_SUBJECT' "${TMP}/case-l.out" || {
  echo "FAIL: case L error message missing subset check hint" >&2
  cat "${TMP}/case-l.out" >&2
  exit 1
}

echo "==> case M: subject authorized for both Sanity and RadGnaRack Vercel"
rm -f "${WORK}/.env"
rm -f "$(policy_path)"
run_writer_and_render \
  CURSOR_OIDC_SUBJECTS=user:alpha,user:beta \
  SANITY_CURSOR_OIDC_SUBJECTS=user:alpha \
  RADGNARRACK_VERCEL_CURSOR_OIDC_SUBJECTS=user:alpha
assert_cursor_capabilities "user:alpha" yes yes
assert_cursor_capabilities "user:beta" no no
assert_gce_least_privilege
assert_sanity_bindings
assert_vercel_secret_prefix_isolation

echo "OK: subject config contract tests passed"
