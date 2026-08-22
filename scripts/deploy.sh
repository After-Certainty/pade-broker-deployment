#!/usr/bin/env bash
# Deploy the runtime image to Cloud Run. Secret names and mount paths only — never values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

require_cmd gcloud
require_project
load_versions

RT="$(runtime_image)"
SA="$(runtime_sa_email)"
BINDINGS="$(bindings_file_rel)"

GITHUB_KEY_MOUNT="/run/secrets/github-app/private-key.pem"
GA_SA_MOUNT="/run/secrets/google-analytics/sa.json"
VERCEL_TOKEN_MOUNT="/run/secrets/vercel/token"

ENV_VARS="PADE_VERSION=${PADE_VERSION},PADE_REF=${PADE_REF}"
# Optional provenance from CI (full deployment-repo git SHA). Local deploys omit this.
if [[ -n "${DEPLOYMENT_GIT_SHA:-}" ]]; then
  ENV_VARS="${ENV_VARS},DEPLOYMENT_GIT_SHA=${DEPLOYMENT_GIT_SHA}"
fi

# Always mount GitHub App PEM + GA SA. Shared Vercel token (Milestone L) is opt-in:
# set MOUNT_SHARED_VERCEL_TOKEN=1 when using static-token-file fulfillment.
# Milestone M subject-secret-wif does not use this mount.
SECRETS="${GITHUB_KEY_MOUNT}=${GITHUB_APP_KEY_SECRET}:latest,${GA_SA_MOUNT}=${GA_SA_SECRET}:latest"
case "${MOUNT_SHARED_VERCEL_TOKEN:-0}" in
  1|true|TRUE|yes|YES)
    SECRETS="${SECRETS},${VERCEL_TOKEN_MOUNT}=${VERCEL_TOKEN_SECRET}:latest"
    echo "==> Mounting shared Vercel token (${VERCEL_TOKEN_SECRET} → ${VERCEL_TOKEN_MOUNT})"
    ;;
  *)
    echo "==> Omitting shared Vercel token mount (Milestone M / subject-secret-wif)"
    echo "    Set MOUNT_SHARED_VERCEL_TOKEN=1 to remount for Milestone L static-token-file."
    ;;
esac

echo "==> gcloud run deploy ${SERVICE}"
echo "    image=${RT}"
echo "    bindings=${BINDINGS}"
echo "    secret_mounts=${SECRETS}"

# Cloud Run allows one secret volume per mount directory; use separate subdirs.
gcloud run deploy "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${RT}" \
  --service-account="${SA}" \
  --args="-tls-termination=proxy,-policy,/config/policy.yaml,-bindings,/config/bindings.yaml,-resolve-timeout,25s,-max-concurrent-resolves,32" \
  --set-env-vars="${ENV_VARS}" \
  --set-secrets="${SECRETS}" \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=3 \
  --timeout=60 \
  --ingress=all \
  --no-invoker-iam-check \
  --quiet

echo "==> Deployed URL:"
gcloud run services describe "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(status.url)'
echo "==> Predicted URL:"
"${ROOT}/scripts/predict-broker-url.sh"
echo "==> Secret env refs (values not shown):"
gcloud run services describe "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='yaml(spec.template.spec.containers[0].env)'
