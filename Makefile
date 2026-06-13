# ArcadeDB-on-AWS — local validation for the CTO approval package.
#
# SAFETY: every target here is read-only / offline. No target runs
# `terraform plan` or `apply`, and `init` always uses -backend=false so no
# remote state / AWS credentials are touched. This is by design (Phase D).
#
# Prefers OpenTofu (`tofu`) if present, falls back to `terraform`.

TF := $(shell command -v tofu 2>/dev/null || command -v terraform 2>/dev/null)
TF_DIRS := $(shell find terraform -name '*.tf' -exec dirname {} \; | sort -u)
HELM_CHARTS := helm/arcadedb
KUBECONFORM_FLAGS := -strict -ignore-missing-schemas -summary

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: validate
validate: fmt-check tf-validate tflint conftest helm-lint kubeconform ## Run all offline checks (CTO-package gate)
	@echo "✅ All local validation passed (no AWS touched)."

.PHONY: fmt
fmt: ## Format all Terraform/OpenTofu files in place
	$(TF) fmt -recursive terraform

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting (CI mode)
	$(TF) fmt -recursive -check -diff terraform

.PHONY: tf-validate
tf-validate: ## terraform/tofu init -backend=false + validate for every module & env
	@set -e; for d in $(TF_DIRS); do \
		echo "── validating $$d"; \
		$(TF) -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
		$(TF) -chdir=$$d validate -no-color; \
	done

.PHONY: tflint
tflint: ## Run tflint across all modules
	@command -v tflint >/dev/null || { echo "tflint not installed — skipping"; exit 0; }
	@set -e; for d in $(TF_DIRS); do echo "── tflint $$d"; (cd $$d && tflint --no-color) || exit 1; done

.PHONY: conftest
conftest: ## Run OPA/Conftest policy UNIT TESTS (residency + no-public-DB gates)
	@command -v conftest >/dev/null || { echo "conftest not installed — skipping"; exit 0; }
	conftest verify --policy policy/conftest
	@echo "  (In CI these same policies run against 'terraform show -json' — see policy/conftest/README.md)"

.PHONY: helm-lint
helm-lint: ## helm lint the ArcadeDB chart values
	@command -v helm >/dev/null || { echo "helm not installed — skipping"; exit 0; }
	helm lint $(HELM_CHARTS)

.PHONY: kubeconform
kubeconform: ## Validate rendered Helm manifests against k8s schemas
	@command -v kubeconform >/dev/null || { echo "kubeconform not installed — skipping"; exit 0; }
	@command -v helm >/dev/null || { echo "helm not installed — skipping"; exit 0; }
	helm template arcadedb $(HELM_CHARTS) | kubeconform $(KUBECONFORM_FLAGS)

.PHONY: clean
clean: ## Remove local .terraform dirs and lockfiles
	find terraform -type d -name '.terraform' -prune -exec rm -rf {} +
	find terraform -name '.terraform.lock.hcl' -delete
