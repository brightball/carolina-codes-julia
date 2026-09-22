JULIA ?= $(shell command -v julia 2>/dev/null || echo $(HOME)/.juliaup/bin/julia)
# Prefer real binaries over broken mise shims.
export PATH := $(HOME)/.local/bin:$(HOME)/.local/share/mise/installs/gitleaks/latest:$(HOME)/.local/share/mise/installs/trivy/latest:$(HOME)/.juliaup/bin:$(PATH)

SEMGREP_CONFIG ?= vendor/semgrep-rules-julia
GITLEAKS ?= gitleaks
TRIVY ?= trivy
SEMGREP ?= semgrep

.PHONY: instantiate instantiate-qa test run format format-fix sast audit gitleaks check hooks

instantiate:
	$(JULIA) --project=. -e 'using Pkg; Pkg.instantiate()'

instantiate-qa:
	$(JULIA) --project=qa -e 'using Pkg; Pkg.instantiate()'

test: instantiate instantiate-qa
	$(JULIA) --threads=auto,1 --project=. test/runtests.jl
	$(JULIA) --project=qa qa/check.jl

run: instantiate
	$(JULIA) --threads=auto,1 --project=. server.jl

format:
	$(JULIA) --project=format -e 'using Pkg; Pkg.instantiate()'
	$(JULIA) --project=format format/check.jl

format-fix:
	$(JULIA) --project=format -e 'using Pkg; Pkg.instantiate()'
	FORMAT_FIX=1 $(JULIA) --project=format format/check.jl

sast:
	$(SEMGREP) --error --metrics=off --config $(SEMGREP_CONFIG) src server.jl test

audit:
	$(TRIVY) fs --scanners vuln --pkg-types library --exit-code 1 --ignore-unfixed --ignore-policy trivy-ignore.rego .

gitleaks:
	$(GITLEAKS) detect --source . --no-git --redact --verbose --exit-code 1

check: test sast audit gitleaks format

hooks:
	pre-commit install
