# carolina-codes-julia

Operating manual for this read-only v1 polyglot API. **Julia** + **HTTP.jl**. Commands and versions are in `README.md`.

## Decision tracking

Julia’s reproducible unit is the package environment (`Project.toml` `[compat]`, `Manifest.toml`). This repo keeps durable choices in one root `DECISIONS.md` and current pins in one root `MEMORY.md`. There is no `docs/decisions/` tree and no amendment log; git history is the changelog.

Before an architectural change, read `DECISIONS.md` and `MEMORY.md`. When a durable choice changes, update `DECISIONS.md` in the same change. When the Julia version, HTTP.jl version, or another named package version changes, refresh `README.md` and `MEMORY.md` in the same change. Those files are an index. They are not a second lockfile. `Project.toml` and `Manifest.toml` stay authoritative.

## Contract

The Phoenix CMS (`Carolina.Polyglot`) keeps at most one language API warm and reads speakers and sponsors from it. This process:

1. Queries PostgreSQL **`v1_*` views** only. Never query Ash tables.
2. Serves the read-only routes below as ordinary JSON. Ash JSON:API (`application/vnd.api+json`) is out of contract.
3. Registers **once** on boot. No heartbeat. If `CAROLINA_URL` is empty, `POLYGLOT_REGISTER_TOKEN` is empty, or the POST fails, log and keep serving.

The HTTP contract is the CMS repo’s `priv/api/openapi.yaml` and `priv/api/AGENTS.md`. This tree has no OpenAPI file, Compose file, or seed catalog. Leave them in the CMS remote.

Handlers query `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, and `v1_year_sponsors`. Year-scoped speaker rows include `languages` and `topics`. Year-scoped sponsor rows include `tier` and `blurb`. This repo does not vendor the database and does not pin a Postgres major version.

### Routes

List payloads are `{ "data": [ ... ] }`. Unknown slugs return 404 `{ "error": "not_found" }`. Non-GET requests return that same 404.

- `GET /health` returns `{ "status": "ok" }` and does not touch Postgres or wait on registration.
- `GET /` returns identity: `language` `Julia`, `framework` `HTTP.jl`, plus `language_version`, `api_version`, `created_year`, `schema_version`, and `endpoints`.
- `GET /v1/years`
- `GET /v1/speakers` and `GET /v1/speakers?year=`
- `GET /v1/speakers/{slug}` and `GET /v1/speakers/{year}/{slug}`
- `GET /v1/sponsors` and `GET /v1/sponsors?year=`
- `GET /v1/sponsors/{slug}` and `GET /v1/sponsors/{year}/{slug}`

`photo_path` and `logo_path` are web paths. Return the path. This process does not serve image bytes.

### Register on boot

`POST {CAROLINA_URL}/internal/api-endpoints/register` with `Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}` and `Content-Type: application/json`. The body is the `GET /` identity document plus `base_url` (`PUBLIC_BASE_URL`). `CarolinaCodes.schedule_registration` starts that POST on the default thread pool after listen, so a slow CMS cannot block `GET /health`.

### Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | `v1_*` views |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | CMS base URL; empty skips register |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer for register; empty skips register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4025` | URL the CMS will call |
| `PORT` | `4025` locally, `8080` in the image | Listen port |

## This API

`server.jl` calls `CarolinaCodes.run_server()`. Routing and SQL live in `CarolinaCodes.handle_get`. `bin/server` launches that with `--threads=auto,1` and `--project`.

Catalog access is LibPQ.jl. `GET /health` and `GET /` never open a connection. A closed pooled connection is replaced on the next query.

`make test` runs the `Test` stdlib against `handle_get` with a fake catalog (no Postgres, no listen), then Aqua.jl from the `qa/` project. Aqua and JuliaFormatter stay out of the runtime `Project.toml` so the image instantiate does not install them. Formatter check-mode is `format/check.jl`.

Quality gates, local and in `.gitea/workflows/checks.yml`: `make test`, `make sast` (Semgrep with vendored `vendor/semgrep-rules-julia`), `make audit` (Trivy), `make gitleaks`, `make format`. `make check` runs all five. `make hooks` installs the same five as pre-commit hooks.

Local default listen is **4025**. The container sets `PORT=8080`. The image is `julia:1.12-bookworm`. Build-time `Pkg.precompile()` writes `CarolinaCodes`, HTTP, LibPQ, and JSON into `JULIA_DEPOT_PATH` with `JULIA_CPU_TARGET=generic`, and the runtime loads that depot. Fly stops idle machines with `suspend`.

This repository is its own git remote. The Phoenix CMS is a different remote (`github.com/brightball/carolina-codes`). Cloud agents treat **this repo** as the workspace root. Sibling checkouts are not guaranteed. Do not fold this tree into the CMS remote.

## Commands

```bash
make test        # fake-catalog handler tests, then Aqua from qa/
make sast        # Semgrep, vendored JuliaComputing/semgrep-rules-julia
make audit       # Trivy filesystem scan
make gitleaks    # secret scan
make format      # JuliaFormatter check-mode (format/)
make check       # all five
make hooks       # pre-commit install
```

`./bin/server` listens after the variables in the table are set. See `README.md` for the copy-paste local command and the version pins.
