# carolina-codes-julia

Read-only v1 polyglot API for Carolina Code Conference. **Julia** + **HTTP.jl**.

Catalog SQL uses LibPQ.jl against PostgreSQL `v1_*` views. HTTP is a thin HTTP.jl callback over `CarolinaCodes.handle_get`, which the `Test` stdlib drives without a live listen.

```bash
make test
```

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4025 \
PORT=4025 \
./bin/server
```

`GET /` reports `language: "Julia"` and `framework: "HTTP.jl"`. `GET /health` returns `{"status":"ok"}` without touching Postgres. Listen port is **4025**.
