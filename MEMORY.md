# Memory

Current pins and gotchas for this Julia + HTTP.jl repo. Rationale is in `DECISIONS.md`. Versions below must match `Project.toml`, `Manifest.toml`, `Dockerfile`, and `scripts/ci-env.sh`. When a pin changes, update this file and `README.md` in the same change.

## Toolchain

- Image and CI: Julia **1.12** (`Dockerfile` `FROM julia:1.12-bookworm`; CI juliaup channel `1.12`).
- Lock: `Manifest.toml` `julia_version` **1.12.7**. Compat floor: `julia = "1.10"`.
- Runtime compat, also the locked versions: HTTP.jl **2.6.7**, LibPQ.jl **1.18.0**, JSON.jl **1.7.1**.
- Aqua.jl compat **0.8**, locked **0.8.18** in `qa/Manifest.toml`. Not in the image.
- JuliaFormatter compat **2**, locked **2.14.0** in `format/Manifest.toml`. Not in the image.
- The `qa/` environment resolves its own HTTP (currently 2.7.1). That lock is only for Aqua. The runtime lock is HTTP.jl 2.6.7.
- Semgrep rules: vendored `vendor/semgrep-rules-julia` (JuliaComputing/semgrep-rules-julia).
- Trivy **0.74.0**, gitleaks **8.30.1** (`mise.toml`, CI install). Ignore policy: `trivy-ignore.rego`.

## Ports and process

- Local default `PORT` is **4025** (`listen_port()`, `./bin/server`).
- Container `ENV PORT=8080`. Fly `[env] PORT` and `internal_port` are 8080. Idle stop is `suspend`. VM is 2048 MB, one shared CPU.
- Launch flag: `--threads=auto,1`. Registration must stay on the default pool.
- `GET /` language is `Julia`, framework is `HTTP.jl`, `api_version` is `0.2.0`, `created_year` is 2026, `schema_version` is 1.
- `language_version` is `string(VERSION)` at runtime, so it follows the Julia that actually runs.

## Gotchas

- `GET /health` does not open LibPQ and does not wait on the register POST.
- If `DATABASE_URL` has no `sslmode=`, the client appends `sslmode=disable`.
- An unusable pooled connection is discarded and reopened. Tests inject `QUERY_HOOK` and `CONNECT_HOOK`.
- Register endpoint entries are maps (`method`, `path`, `query`), the same objects `GET /` returns. They are not bare `"GET /path"` strings.
- No `openapi.yaml`, Compose file, or seed SQL in this tree. Contract: CMS `priv/api/openapi.yaml`.
- This repo is its own git remote. Do not assume a sibling CMS checkout.
- Image startup is depot precompile with `JULIA_CPU_TARGET=generic` and `JULIA_DEPOT_PATH=/opt/julia`.
