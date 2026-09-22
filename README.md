# carolina-codes-julia

Read-only v1 polyglot API for Carolina Code Conference. **Julia** + **HTTP.jl**.

Catalog SQL uses LibPQ.jl against PostgreSQL `v1_*` views. HTTP is a thin HTTP.jl callback over `CarolinaCodes.handle_get`, which the `Test` stdlib drives without a live listen.

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

`GET /` reports `language: "Julia"` and `framework: "HTTP.jl"`. `GET /health` returns `{"status":"ok"}` without touching Postgres and without waiting on Elixir registration. Listen port is **4025**.

`make test` also runs [Aqua.jl](https://github.com/JuliaTesting/Aqua.jl) from the test-only `qa/` project (method ambiguities, unbound type parameters, piracy, and project/dependency consistency). Aqua is not an image dependency. The container precompiles `CarolinaCodes`, HTTP, LibPQ, and JSON into `JULIA_DEPOT_PATH` and loads that cache at startup (`JULIA_CPU_TARGET=generic`). Fly stops idle machines with `suspend`.
