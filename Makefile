# Thin Make wrappers around explicit gcloud/docker commands.
# See README.md for the deploy workflow.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(ROOT)/scripts

.PHONY: help bootstrap-gcp bootstrap-github-wif bootstrap-cursor-wif \
	check-aws-s3 bootstrap-aws-s3 show-aws-s3 teardown-aws-s3 \
	predict-url render-config print-agent-bindings print-agent-bindings-gce \
	pull-broker build push secret-github-app secret-ga-sa secret-vercel-token secret-vercel-token-subject \
	secret-sanity-token-subject \
	deploy health authz-smoke logs teardown-docs describe-url validate-remote \
	test-providers test-config-contract

help:
	@echo "Targets:"
	@echo "  bootstrap-gcp                Enable APIs; AR repo; runtime SA; IAM"
	@echo "  bootstrap-github-wif         Deployer SA + GitHub OIDC / WIF (admin, rare)"
	@echo "  bootstrap-cursor-wif         Cursor OIDC → GCP WIF pool (runtime subject-bound auth)"
	@echo "  check-aws-s3                 Experiment 007 Phase 3 AWS role preflight (workstation)"
	@echo "  bootstrap-aws-s3             Create/reconcile Phase 3 AWS role (workstation; not GHA)"
	@echo "  show-aws-s3                  Show Phase 3 AWS role + ARN to set in GitHub Environment"
	@echo "  teardown-aws-s3              Delete Phase 3 AWS role only (not Phase 2 / bucket)"
	@echo "  predict-url                  Print deterministic Cloud Run HTTPS URL"
	@echo "  render-config                Render policy/bindings from templates + .env"
	@echo "  print-agent-bindings         Print Cursor agent YAML pointed at the predicted URL"
	@echo "  print-agent-bindings-gce     Print GCE agent YAML (identity: gce) at the predicted URL"
	@echo "  pull-broker                  Pull released ghcr.io/after-certainty/pade-broker"
	@echo "  build                        Render config; build runtime overlay"
	@echo "  push                         Push runtime overlay to Artifact Registry"
	@echo "  secret-github-app            Populate GitHub App PEM in Secret Manager (stdin/env)"
	@echo "  secret-ga-sa                 Populate GA service account JSON in Secret Manager (stdin/env)"
	@echo "  secret-vercel-token          Populate shared Vercel token (static-token-file opt-in)"
	@echo "  secret-vercel-token-subject  Populate subject-bound Vercel token (recommended; SUBJECT=…)"
	@echo "  secret-sanity-token-subject  Populate subject-bound Sanity token (SUBJECT=…)"
	@echo "  deploy                       Deploy runtime image to Cloud Run"
	@echo "  health                       Stage 2 GET /healthz"
	@echo "  authz-smoke                  Stage 3 unauthenticated /v1/resolve → 401"
	@echo "  logs                         Recent broker Cloud Logging lines"
	@echo "  describe-url                 Print deployed status.url"
	@echo "  teardown-docs                Print teardown commands (no deletes)"
	@echo "  test-providers               Unit-test deployment-owned exec providers (vercel, aws-s3, sanity)"
	@echo "  test-config-contract         Subject allowlist contract (GHA .env writer + render-config)"
	@echo "  validate-remote              health + authz-smoke against deployed URL"

bootstrap-gcp:
	@$(SCRIPTS)/bootstrap-gcp.sh

bootstrap-github-wif:
	@$(SCRIPTS)/bootstrap-github-wif.sh

bootstrap-cursor-wif:
	@$(SCRIPTS)/bootstrap-cursor-wif.sh

check-aws-s3:
	@$(SCRIPTS)/check-aws-s3.sh

bootstrap-aws-s3:
	@$(SCRIPTS)/bootstrap-aws-s3.sh

show-aws-s3:
	@$(SCRIPTS)/show-aws-s3.sh

teardown-aws-s3:
	@$(SCRIPTS)/teardown-aws-s3.sh

predict-url:
	@$(SCRIPTS)/predict-broker-url.sh

render-config:
	@$(SCRIPTS)/render-config.sh

print-agent-bindings:
	@$(SCRIPTS)/print-agent-bindings.sh

print-agent-bindings-gce:
	@$(SCRIPTS)/print-agent-bindings-gce.sh

pull-broker:
	@source "$(SCRIPTS)/lib.sh" && require_cmd docker && load_versions && \
	BROKER="$$(broker_image)" && \
	echo "==> docker pull $$BROKER" && \
	docker pull --platform="$${DOCKER_PLATFORM}" "$$BROKER"

build: render-config pull-broker
	@source "$(SCRIPTS)/lib.sh" && require_cmd docker && require_project && load_versions && \
	BROKER="$$(broker_image)" && \
	IMG="$$(runtime_image)" && \
	BINDINGS="$$(bindings_file_rel)" && \
	echo "==> docker build $$IMG" && \
	echo "    base=$$BROKER" && \
	echo "    overlay bindings=$$BINDINGS exec providers from $${PADE_VERSION}" && \
	docker build \
	  --platform="$${DOCKER_PLATFORM}" \
	  -t "$$IMG" \
	  -f "$(ROOT)/docker/Dockerfile.runtime" \
	  --build-arg "BASE_IMAGE=$$BROKER" \
	  --build-arg "PADE_REPO=$${PADE_REPO}" \
	  --build-arg "PADE_VERSION=$${PADE_VERSION}" \
	  "$(ROOT)"

push:
	@source "$(SCRIPTS)/lib.sh" && require_cmd docker gcloud && require_project && load_versions && \
	echo "==> gcloud auth configure-docker $${REGION}-docker.pkg.dev" && \
	gcloud auth configure-docker "$${REGION}-docker.pkg.dev" --quiet && \
	RT="$$(runtime_image)" && \
	echo "==> docker push $$RT" && \
	docker push "$$RT"

secret-github-app:
	@$(SCRIPTS)/populate-github-app-secret.sh

secret-ga-sa:
	@$(SCRIPTS)/populate-ga-sa-secret.sh

secret-vercel-token:
	@$(SCRIPTS)/populate-vercel-token-secret.sh

secret-vercel-token-subject:
	@$(SCRIPTS)/populate-vercel-token-subject-secret.sh

secret-sanity-token-subject:
	@$(SCRIPTS)/populate-sanity-token-subject-secret.sh

test-providers:
	@cd "$(ROOT)/providers/vercel" && go test ./...
	@cd "$(ROOT)/providers/aws-s3" && go test ./...
	@cd "$(ROOT)/providers/sanity" && go test ./...

test-config-contract:
	@$(SCRIPTS)/test-subject-config-contract.sh

deploy:
	@$(SCRIPTS)/deploy.sh

describe-url:
	@source "$(SCRIPTS)/lib.sh" && require_cmd gcloud && require_project && load_versions && \
	gcloud run services describe "$${SERVICE}" \
	  --project="$${PROJECT_ID}" \
	  --region="$${REGION}" \
	  --format='value(status.url)'

health:
	@$(SCRIPTS)/health.sh

authz-smoke:
	@$(SCRIPTS)/authz-smoke.sh

logs:
	@$(SCRIPTS)/logs.sh

teardown-docs:
	@$(SCRIPTS)/print-teardown.sh

validate-remote: health authz-smoke
	@echo "Stages 2–3 passed. Stages 4+ can use a Cursor Cloud Agent or a GCE Coder workspace (see docs/validation.md)."
