# Thin Make wrappers around explicit gcloud/docker commands.
# See README.md for the deploy workflow.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(ROOT)/scripts

.PHONY: help bootstrap-gcp bootstrap-github-wif bootstrap-cursor-wif predict-url render-config print-agent-bindings \
	pull-broker build push secret-github-app secret-ga-sa secret-vercel-token secret-vercel-token-subject \
	deploy health authz-smoke logs teardown-docs describe-url validate-remote \
	test-providers

help:
	@echo "Targets:"
	@echo "  bootstrap-gcp                Enable APIs; AR repo; runtime SA; IAM"
	@echo "  bootstrap-github-wif         Deployer SA + GitHub OIDC / WIF (admin, rare)"
	@echo "  bootstrap-cursor-wif         Cursor OIDC → GCP WIF pool (Milestone M)"
	@echo "  predict-url                  Print deterministic Cloud Run HTTPS URL"
	@echo "  render-config                Render policy/bindings from templates + .env"
	@echo "  print-agent-bindings         Print agent YAML pointed at the predicted URL"
	@echo "  pull-broker                  Pull released ghcr.io/after-certainty/pade-broker"
	@echo "  build                        Render config; build runtime overlay"
	@echo "  push                         Push runtime overlay to Artifact Registry"
	@echo "  secret-github-app            Populate GitHub App PEM in Secret Manager (stdin/env)"
	@echo "  secret-ga-sa                 Populate GA service account JSON in Secret Manager (stdin/env)"
	@echo "  secret-vercel-token          Populate shared Vercel token (Milestone L)"
	@echo "  secret-vercel-token-subject  Populate subject-bound Vercel token (Milestone M; SUBJECT=…)"
	@echo "  deploy                       Deploy runtime image to Cloud Run"
	@echo "  health                       Stage 2 GET /healthz"
	@echo "  authz-smoke                  Stage 3 unauthenticated /v1/resolve → 401"
	@echo "  logs                         Recent broker Cloud Logging lines"
	@echo "  describe-url                 Print deployed status.url"
	@echo "  teardown-docs                Print teardown commands (no deletes)"
	@echo "  test-providers               Unit-test deployment-owned exec providers"
	@echo "  validate-remote              health + authz-smoke against deployed URL"

bootstrap-gcp:
	@$(SCRIPTS)/bootstrap-gcp.sh

bootstrap-github-wif:
	@$(SCRIPTS)/bootstrap-github-wif.sh

bootstrap-cursor-wif:
	@$(SCRIPTS)/bootstrap-cursor-wif.sh

predict-url:
	@$(SCRIPTS)/predict-broker-url.sh

render-config:
	@$(SCRIPTS)/render-config.sh

print-agent-bindings:
	@$(SCRIPTS)/print-agent-bindings.sh

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

test-providers:
	@cd "$(ROOT)/providers/vercel" && go test ./...

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
	@echo "Stages 2–3 passed. Stages 4–6 require a Cursor Cloud Agent (see docs/validation.md)."
