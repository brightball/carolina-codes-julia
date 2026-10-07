# carolina-codes-julia

Read-only v1 polyglot API for Carolina Code Conference. **Julia** + **HTTP.jl**.

Language **Julia 1.12** for the image (`julia:1.12-bookworm`) and for CI (`scripts/ci-env.sh` installs channel 1.12). `Manifest.toml` records `julia_version` 1.12.7. The `Project.toml` compat floor is **1.10**.

Framework **HTTP.jl 2.6.7**. Other runtime packages, pinned in `Project.toml` `[compat]` and locked at those same versions in `Manifest.toml`: LibPQ.jl **1.18.0** and JSON.jl **1.7.1**.

Catalog SQL uses LibPQ.jl against PostgreSQL `v1_*` views. HTTP is a thin HTTP.jl callback over `CarolinaCodes.handle_get`, which the `Test` stdlib drives without a live listen.

[Aqua.jl](https://github.com/JuliaTesting/Aqua.jl) (compat 0.8) is test-only, in the `qa/` project. JuliaFormatter (compat 2) is format-only, in the `format/` project. Neither is copied into the image.

The container precompiles `CarolinaCodes`, HTTP, LibPQ, and JSON into `JULIA_DEPOT_PATH` at image build and loads that depot cache at startup (`JULIA_CPU_TARGET=generic`). Fly stops idle machines with `suspend`.

```bash
make test        # fake-catalog handler tests (no live Postgres) plus Aqua.jl
make sast        # Semgrep + vendored JuliaComputing/semgrep-rules-julia
make audit       # Trivy filesystem scan of Manifest.toml / Project.toml
make gitleaks    # committed-secret scan of this git tree
make format      # JuliaFormatter check-mode
make check       # all five
make hooks       # install local pre-commit hooks
```

Pre-commit runs the same five checks (`tests`, `static security scanner`, `3rd-party dependency scanner`, `gitleaks`, `JuliaFormatter`). Install once with `make hooks` (needs `pre-commit` on PATH). Emergency skip: `SKIP=test,sast,audit,gitleaks,format git commit`. Gitea Actions runs each check as its own job under `.gitea/workflows/checks.yml`.

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4025 \
PORT=4025 \
./bin/server
```

`GET /` reports `language: "Julia"` and `framework: "HTTP.jl"`. `GET /health` returns `{"status":"ok"}` without touching Postgres and without waiting on Elixir registration. Listen port is **4025** locally and **8080** in the container.

`make test` runs the fake-catalog handler tests, then Aqua from `qa/`. Operating rules for agents are in `AGENTS.md`. Accepted choices are in `DECISIONS.md`. Version pins and gotchas are in `MEMORY.md`.
