# Decisions

Accepted choices for this Julia + HTTP.jl API. One choice per section. Status stays `accepted` until a later change replaces that section. Git history is the changelog. Do not add an amendment log here.

Dates are the commits that settled the choice. `MEMORY.md` lists the current pins. `Project.toml` and `Manifest.toml` are the lock.

## HTTP.jl instead of a larger web framework

- Status: accepted
- Date: 2026-09-05
- Choice: `server.jl` is a thin HTTP.jl entry. `CarolinaCodes.handle_get` owns routing. `HTTP.serve!` only accepts.
- Why: The `Test` stdlib calls `handle_get` with no live listen. A full framework (routing DSL, middleware stack, or an app generator) would own the routes and enlarge the image. One identity document serves `GET /` and the boot-time register body.

## LibPQ against `v1_*` views

- Status: accepted
- Date: 2026-09-05
- Choice: Catalog SQL goes through LibPQ.jl and only the `v1_*` views (`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`).
- Why: Those views are the polyglot contract. Ash tables belong to the CMS. This repo does not vendor Postgres or pin a major version.

## Test-stdlib fake catalog

- Status: accepted
- Date: 2026-09-05
- Choice: `test/runtests.jl` drives the shipped `handle_get` (and the HTTP handler) through a fake catalog hook. `make test` does not need Postgres or an open port.
- Why: Handler behavior is the contract under test. A live database would couple every check to the CMS catalog.

## Aqua and JuliaFormatter stay out of the runtime project

- Status: accepted
- Date: 2026-09-22
- Choice: Aqua.jl lives in `qa/`. JuliaFormatter lives in `format/`. The root `Project.toml` runtime deps are HTTP, LibPQ, and JSON, plus the `Test` stdlib target.
- Why: The image runs `Pkg.instantiate()` on the app project. Tooling in that project would ship inside `JULIA_DEPOT_PATH`. Side environments keep Aqua and JuliaFormatter on the quality path only.

## Generic CPU target and depot precompile

- Status: accepted
- Date: 2026-09-22
- Choice: The image sets `JULIA_CPU_TARGET=generic` and `JULIA_DEPOT_PATH=/opt/julia`. The build runs `Pkg.precompile()` for `CarolinaCodes`, HTTP, LibPQ, and JSON, calls `handle_get` on `/health` and `/`, and the runtime loads that depot. Fly idle machines use `suspend` at 2048 MB.
- Why: On 2026-09-05, native-CPU code compiled in Docker was rebuilt on Fly and OOM-killed a small machine. A generic depot cache is the startup path that stayed on `master`. `GET /health` still does no catalog I/O.

## Five quality gates

- Status: accepted
- Date: 2026-09-22
- Choice: `make test`, `make sast`, `make audit`, `make gitleaks`, and `make format` are the gates. Pre-commit runs the same five. Gitea Actions runs one prepare job, then each gate as its own job (`.gitea/workflows/checks.yml`).
- Why: Semgrep uses the vendored JuliaComputing rules. Trivy scans library deps. gitleaks scans the tree. JuliaFormatter is check-mode unless `FORMAT_FIX=1`. Splitting CI jobs keeps a formatter failure from hiding a test failure.

## Register off the accept loop

- Status: accepted
- Date: 2026-09-22
- Choice: After `HTTP.serve!` binds, `schedule_registration` runs the CMS POST once on the default thread pool (`Threads.@spawn`). Empty `CAROLINA_URL` or token skips it. A failed POST is logged. Serving continues either way. Launch with `--threads=auto,1`.
- Why: `HTTP.serve!` accepts on the interactive thread. A register call on that thread would stall `/health` when the CMS is slow or down. There is no heartbeat.
