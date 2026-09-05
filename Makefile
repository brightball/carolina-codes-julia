JULIA ?= $(shell command -v julia 2>/dev/null || echo $(HOME)/.juliaup/bin/julia)

.PHONY: instantiate test run

instantiate:
	$(JULIA) --project=. -e 'using Pkg; Pkg.instantiate()'

test: instantiate
	$(JULIA) --project=. test/runtests.jl

run: instantiate
	$(JULIA) --project=. server.jl
