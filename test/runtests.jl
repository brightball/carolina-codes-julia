using Test
using JSON
using HTTP
using LibPQ
using Sockets
using CarolinaCodes

function fake_query(sql::AbstractString, args)
    if occursin("FROM v1_speakers WHERE slug =", sql)
        if !isempty(args) && string(args[1]) == "diana-pham"
            return [
                Dict{String,Any}(
                    "slug" => "diana-pham",
                    "first_name" => "Diana",
                    "last_name" => "Pham",
                    "name" => "Diana Pham",
                ),
            ]
        end
        return Dict{String,Any}[]
    end
    if occursin("FROM v1_speakers", sql)
        return [
            Dict{String,Any}(
                "slug" => "diana-pham",
                "first_name" => "Diana",
                "last_name" => "Pham",
                "name" => "Diana Pham",
            ),
        ]
    end
    if occursin("FROM v1_talks", sql)
        return [
            Dict{String,Any}(
                "slug" => "talk",
                "title" => "Talk",
                "speaker_slug" => "diana-pham",
                "year" => 2026,
                "languages" => "{php}",
                "topics" => "{development}",
            ),
        ]
    end
    if occursin("FROM v1_year_sponsors", sql)
        if length(args) >= 2 && string(args[2]) != "flywheel"
            return Dict{String,Any}[]
        end
        return [
            Dict{String,Any}(
                "slug" => "flywheel",
                "name" => "Flywheel",
                "tier" => "platinum",
                "year" => 2026,
            ),
        ]
    end
    if occursin("FROM v1_sponsorships", sql) && occursin("DISTINCT year", sql)
        return [Dict{String,Any}("year" => 2026), Dict{String,Any}("year" => 2025)]
    end
    if occursin("FROM v1_sponsorships", sql)
        return [
            Dict{String,Any}(
                "sponsor_slug" => "flywheel",
                "year" => 2026,
                "tier" => "platinum",
            ),
        ]
    end
    if occursin("FROM v1_sponsors WHERE slug", sql)
        if !isempty(args) && string(args[1]) == "flywheel"
            return [
                Dict{String,Any}(
                    "slug" => "flywheel",
                    "name" => "Flywheel",
                    "website" => "https://getflywheel.com",
                ),
            ]
        end
        return Dict{String,Any}[]
    end
    if occursin("FROM v1_sponsors", sql)
        return [
            Dict{String,Any}(
                "slug" => "flywheel",
                "name" => "Flywheel",
                "tier" => "platinum",
                "year" => 2026,
            ),
        ]
    end
    if occursin("FROM v1_years", sql)
        return [
            Dict{String,Any}(
                "year" => 2026,
                "slug" => "2026",
                "name" => "Carolina Code Conference 2026",
                "status" => "past",
            ),
        ]
    end
    return Dict{String,Any}[]
end

CarolinaCodes.QUERY_HOOK[] = fake_query

@testset "carolina handler" begin
    @testset "identity Julia + HTTP.jl" begin
        @test CarolinaCodes.LANGUAGE == "Julia"
        @test CarolinaCodes.FRAMEWORK == "HTTP.jl"
        @test CarolinaCodes.SCHEMA_VERSION == 1
        @test CarolinaCodes.CREATED_YEAR == 2026
        @test CarolinaCodes.LANGUAGE != "Clef"
        @test CarolinaCodes.FRAMEWORK != "AWS"
    end

    @testset "/health JSON without SQL" begin
        reset_counts()
        status, body = handle_get("/health")
        encoded = JSON.json(body)
        @test status == 200
        @test occursin("\"status\"", encoded)
        @test occursin("\"ok\"", encoded)
        @test body["status"] == "ok"
        @test SQL_COUNT[] == 0
        @test CONNECT_COUNT[] == 0
    end

    @testset "/health trailing slash" begin
        reset_counts()
        status, body = handle_get("/health/")
        @test status == 200
        @test body["status"] == "ok"
        @test SQL_COUNT[] == 0
    end

    @testset "GET / identity" begin
        reset_counts()
        status, body = handle_get("/")
        @test status == 200
        @test body["language"] == "Julia"
        @test body["framework"] == "HTTP.jl"
        @test SQL_COUNT[] == 0
        @test CONNECT_COUNT[] == 0
    end

    @testset "unknown speaker slug 404" begin
        reset_counts()
        status, body = handle_get("/v1/speakers/no-such-slug")
        @test status == 404
        @test body["error"] == "not_found"
        @test occursin("not_found", JSON.json(body))
    end

    @testset "year-scoped languages/topics" begin
        reset_counts()
        status, body = handle_get("/v1/speakers", "2026")
        @test status == 200
        @test haskey(body, "data")
        @test !isempty(body["data"])
        row = body["data"][1]
        @test haskey(row, "languages")
        @test haskey(row, "topics")
        @test row["languages"] isa AbstractVector
        @test !isempty(row["languages"])
        @test !isempty(row["topics"])
        @test SQL_COUNT[] > 0
    end

    @testset "year-scoped uses v1_talks" begin
        sqls = String[]
        CarolinaCodes.QUERY_HOOK[] = (sql, args) -> begin
            push!(sqls, sql)
            return fake_query(sql, args)
        end
        status, body = handle_get("/v1/speakers", "2026")
        @test status == 200
        @test any(s -> occursin("v1_talks", s), sqls)
        @test !any(s -> occursin("v1_year_speakers", s), sqls)
        @test occursin("languages", JSON.json(body))
        CarolinaCodes.QUERY_HOOK[] = fake_query
    end

    @testset "year-scoped sponsor tier" begin
        status, body = handle_get("/v1/sponsors", "2026")
        @test status == 200
        @test haskey(body, "data")
        @test !isempty(body["data"])
        @test haskey(body["data"][1], "tier")
        @test body["data"][1]["tier"] == "platinum"
    end

    @testset "years wrapped as data" begin
        status, body = handle_get("/v1/years")
        @test status == 200
        @test haskey(body, "data")
        @test occursin("\"data\"", JSON.json(body))
    end

    @testset "fake catalog skips Postgres" begin
        reset_counts()
        status, _ = handle_get("/v1/speakers", "2026")
        @test status == 200
        @test CONNECT_COUNT[] == 0
    end
end

function response_bytes(resp::HTTP.Response)
    body = resp.body
    return body isa HTTP.BytesBody ? copy(body) : UInt8[]
end

function handler_call(method::AbstractString, target::AbstractString)
    resp = http_handler(HTTP.Request(method, target))
    text = String(response_bytes(resp))
    return resp.status, JSON.parse(text), text, resp
end

"""Drive shipped `handle_get` and `http_handler` for one GET target."""
function exercise_get(path::AbstractString, year::AbstractString = "")
    target = isempty(year) ? path : string(path, "?year=", year)
    status, body = handle_get(path, year)
    hstatus, hbody, _, resp = handler_call("GET", target)
    @test status == hstatus
    @test hbody == body
    @test HTTP.header(resp.headers, "Content-Type", "") == "application/json"
    return status, body
end

mutable struct OpenProbe
    id::Int
end
Base.isopen(::OpenProbe) = true

function bad_libpq()
    return LibPQ.Connection(
        "dbname=123fake user=carolina_test";
        throw_error = false,
        connect_timeout = 1,
    )
end

@testset "catalog routes through handle_get and http_handler" begin
    @testset "GET / and GET /health leave the database alone" begin
        reset_counts()
        status, body = exercise_get("/")
        @test status == 200
        @test body["language"] == "Julia"
        @test body["framework"] == "HTTP.jl"
        @test body["schema_version"] == 1
        @test body["endpoints"] == CarolinaCodes.ENDPOINTS
        @test SQL_COUNT[] == 0
        @test CONNECT_COUNT[] == 0

        reset_counts()
        status, body = exercise_get("/health")
        @test status == 200
        @test body == Dict{String,Any}("status" => "ok")
        @test SQL_COUNT[] == 0
        @test CONNECT_COUNT[] == 0
    end

    @testset "list routes" begin
        status, body = exercise_get("/v1/years")
        @test status == 200
        @test body["data"] isa AbstractVector
        @test body["data"][1]["year"] == 2026
        @test body["data"][1]["slug"] == "2026"

        status, body = exercise_get("/v1/speakers")
        @test status == 200
        @test body["data"][1]["slug"] == "diana-pham"

        status, body = exercise_get("/v1/speakers", "2026")
        @test status == 200
        row = body["data"][1]
        @test row["slug"] == "diana-pham"
        @test row["year"] == 2026
        @test row["languages"] == ["php"]
        @test row["topics"] == ["development"]
        @test row["talks"] isa AbstractVector
        @test !isempty(row["talks"])
        @test row["years"] isa AbstractVector

        status, body = exercise_get("/v1/sponsors")
        @test status == 200
        @test body["data"][1]["slug"] == "flywheel"

        status, body = exercise_get("/v1/sponsors", "2026")
        @test status == 200
        @test body["data"][1]["tier"] == "platinum"
        @test body["data"][1]["year"] == 2026
    end

    @testset "detail routes" begin
        status, body = exercise_get("/v1/speakers/diana-pham")
        @test status == 200
        @test body["data"]["slug"] == "diana-pham"
        @test body["data"]["talks"] isa AbstractVector
        @test body["data"]["years"] isa AbstractVector
        @test !isempty(body["data"]["talks"])

        status, body = exercise_get("/v1/speakers/2026/diana-pham")
        @test status == 200
        row = body["data"]
        @test row["slug"] == "diana-pham"
        @test row["year"] == 2026
        @test row["talks"] isa AbstractVector
        @test !isempty(row["talks"])
        @test row["languages"] == ["php"]
        @test row["topics"] == ["development"]
        @test row["years"] isa AbstractVector
        @test row["other_years"] isa AbstractVector

        status, body = exercise_get("/v1/sponsors/flywheel")
        @test status == 200
        @test body["data"]["slug"] == "flywheel"
        @test body["data"]["sponsorships"] isa AbstractVector
        @test !isempty(body["data"]["sponsorships"])

        status, body = exercise_get("/v1/sponsors/2026/flywheel")
        @test status == 200
        row = body["data"]
        @test row["slug"] == "flywheel"
        @test row["tier"] == "platinum"
        @test row["year"] == 2026
        @test row["years"] == [2026, 2025]
        @test row["other_years"] == [2025]
    end

    @testset "unknown slugs and paths" begin
        for path in (
            "/v1/speakers/no-such-slug",
            "/v1/speakers/2026/no-such-slug",
            "/v1/sponsors/missing-sponsor",
            "/v1/sponsors/2026/missing-sponsor",
            "/v1/not-a-route",
            "/missing",
        )
            status, body = exercise_get(path)
            @test status == 404
            @test body == Dict{String,Any}("error" => "not_found")
        end
    end

    @testset "every catalog template is exercised" begin
        covered = Set{String}()
        for (template, path, year) in (
            ("/", "/", ""),
            ("/health", "/health", ""),
            ("/v1/years", "/v1/years", ""),
            ("/v1/speakers", "/v1/speakers", "2026"),
            ("/v1/speakers/:slug", "/v1/speakers/diana-pham", ""),
            ("/v1/speakers/:year/:slug", "/v1/speakers/2026/diana-pham", ""),
            ("/v1/sponsors", "/v1/sponsors", "2026"),
            ("/v1/sponsors/:slug", "/v1/sponsors/flywheel", ""),
            ("/v1/sponsors/:year/:slug", "/v1/sponsors/2026/flywheel", ""),
        )
            status, _ = exercise_get(path, year)
            @test status == 200
            push!(covered, template)
        end
        catalog = Set(String(ep["path"]) for ep in CarolinaCodes.ENDPOINTS)
        @test covered == catalog
        @test all(ep["method"] == "GET" for ep in CarolinaCodes.ENDPOINTS)
    end

    @testset "non-GET is JSON not_found" begin
        reset_counts()
        for (method, target) in (("POST", "/health"), ("PUT", "/"), ("DELETE", "/v1/years"))
            status, body, _, resp = handler_call(method, target)
            @test status == 404
            @test body == Dict{String,Any}("error" => "not_found")
            @test HTTP.header(resp.headers, "Content-Type", "") == "application/json"
        end
        @test SQL_COUNT[] == 0
        @test CONNECT_COUNT[] == 0
    end
end

@testset "unusable pooled connection is not reused" begin
    bad = bad_libpq()
    probe_n = Ref(0)
    CarolinaCodes.CONNECT_HOOK[] = () -> begin
        probe_n[] += 1
        return OpenProbe(probe_n[])
    end
    try
        @test isopen(bad)
        @test LibPQ.status(bad) == LibPQ.libpq_c.CONNECTION_BAD
        @test CarolinaCodes.connection_usable(bad) == false
        CarolinaCodes.CONN[] = bad
        before = CONNECT_COUNT[]
        got = CarolinaCodes.ensure_conn()
        @test got isa OpenProbe
        @test got !== bad
        @test CONNECT_COUNT[] == before + 1
        again = CarolinaCodes.ensure_conn()
        @test again === got
        @test CONNECT_COUNT[] == before + 1
        @test probe_n[] == 1

        closed = bad_libpq()
        close(closed)
        @test isopen(closed) == false
        @test CarolinaCodes.connection_usable(closed) == false
        CarolinaCodes.CONN[] = closed
        replaced = CarolinaCodes.ensure_conn()
        @test replaced isa OpenProbe
        @test replaced !== closed
        @test replaced !== got
        @test probe_n[] == 2
        reused = CarolinaCodes.ensure_conn()
        @test reused === replaced
        @test probe_n[] == 2
    finally
        CarolinaCodes.CONNECT_HOOK[] = nothing
        CarolinaCodes.CONN[] = nothing
    end
end

const SERVER_ENV_KEYS =
    ("PORT", "CAROLINA_URL", "POLYGLOT_REGISTER_TOKEN", "PUBLIC_BASE_URL")

function push_server_env(pairs::Pair...)
    saved = Dict{String,Union{Nothing,String}}()
    for key in SERVER_ENV_KEYS
        saved[key] = get(ENV, key, nothing)
    end
    for (key, value) in pairs
        if value === nothing
            delete!(ENV, String(key))
        else
            ENV[String(key)] = String(value)
        end
    end
    return saved
end

function pop_server_env(saved)
    for (key, value) in saved
        if value === nothing
            delete!(ENV, key)
        else
            ENV[key] = value
        end
    end
    return nothing
end

function raw_http_get(port::Integer, path::AbstractString)
    last_error = ""
    request = "GET $(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
    for addr in (ip"::1", ip"127.0.0.1")
        sock = nothing
        try
            sock = connect(addr, Int(port))
            write(sock, request)
            text = String(readavailable(sock))
            parts = split(text, "\r\n\r\n"; limit = 2)
            if length(parts) != 2
                last_error = "incomplete response from $(addr): $(repr(text))"
                continue
            end
            status = parse(Int, split(String(parts[1]))[2])
            return status, JSON.parse(String(parts[2])), ""
        catch err
            last_error = sprint(showerror, err)
        finally
            sock === nothing || close(sock)
        end
    end
    return nothing, nothing, last_error
end

function finish_registration()
    task = CarolinaCodes.REGISTRATION_TASK[]
    task isa Task || return nothing
    timedwait(() -> istaskdone(task), 20)
    return task
end

@testset "registration does not gate listen" begin
    @test Threads.nthreads(:interactive) >= 1

    @testset "unset registration" begin
        saved = push_server_env(
            "PORT" => "0",
            "CAROLINA_URL" => "",
            "POLYGLOT_REGISTER_TOKEN" => "",
            "PUBLIC_BASE_URL" => "",
        )
        server = CarolinaCodes.run_server(block = false)
        try
            @test CarolinaCodes.REGISTRATION_TASK[] === nothing
            port = HTTP.port(server)
            reset_counts()
            status, body, err = raw_http_get(port, "/health")
            @test err == ""
            @test status == 200
            @test body["status"] == "ok"
            @test SQL_COUNT[] == 0
            @test CONNECT_COUNT[] == 0
            status, body, err = raw_http_get(port, "/")
            @test err == ""
            @test status == 200
            @test body["language"] == "Julia"
            @test body["framework"] == "HTTP.jl"
        finally
            close(server)
            pop_server_env(saved)
        end
    end

    @testset "closed registration host" begin
        listener = listen(ip"127.0.0.1", 0)
        closed_port = Int(getsockname(listener)[2])
        close(listener)
        saved = push_server_env(
            "PORT" => "0",
            "CAROLINA_URL" => "http://127.0.0.1:$(closed_port)",
            "POLYGLOT_REGISTER_TOKEN" => "dev",
        )
        server = CarolinaCodes.run_server(block = false)
        try
            @test CarolinaCodes.REGISTRATION_TASK[] isa Task
            started = time()
            status, body, err = raw_http_get(HTTP.port(server), "/health")
            @test err == ""
            @test status == 200
            @test body["status"] == "ok"
            @test time() - started < 2
        finally
            close(server)
            task = finish_registration()
            @test task isa Task
            @test istaskdone(task)
            pop_server_env(saved)
        end
    end

    @testset "black-holed registration host" begin
        saved = push_server_env(
            "PORT" => "0",
            "CAROLINA_URL" => "http://192.0.2.1:81",
            "POLYGLOT_REGISTER_TOKEN" => "dev",
        )
        server = CarolinaCodes.run_server(block = false)
        try
            @test CarolinaCodes.REGISTRATION_TASK[] isa Task
            started = time()
            status, body, err = raw_http_get(HTTP.port(server), "/health")
            @test err == ""
            @test status == 200
            @test body["status"] == "ok"
            @test time() - started < 2
        finally
            close(server)
            task = finish_registration()
            @test task isa Task
            @test istaskdone(task)
            pop_server_env(saved)
        end
    end

    @testset "slow registration still serves health" begin
        listener = listen(ip"127.0.0.1", 0)
        slow_port = Int(getsockname(listener)[2])
        held = Ref{Any}(nothing)
        accepted = Ref(false)
        @async begin
            try
                sock = accept(listener)
                held[] = sock
                accepted[] = true
                eof(sock)
            catch
            end
        end
        saved = push_server_env(
            "PORT" => "0",
            "CAROLINA_URL" => "http://127.0.0.1:$(slow_port)",
            "POLYGLOT_REGISTER_TOKEN" => "dev",
            "PUBLIC_BASE_URL" => "http://127.0.0.1:9",
        )
        server = CarolinaCodes.run_server(block = false)
        try
            @test timedwait(() -> accepted[], 20) == :ok
            task = CarolinaCodes.REGISTRATION_TASK[]
            @test task isa Task
            @test istaskdone(task) == false
            started = time()
            status, body, err = raw_http_get(HTTP.port(server), "/health")
            @test err == ""
            @test status == 200
            @test body["status"] == "ok"
            @test time() - started < 2
            @test istaskdone(task) == false
        finally
            sock = held[]
            sock === nothing || close(sock)
            close(listener)
            close(server)
            task = finish_registration()
            @test task isa Task
            @test istaskdone(task)
            pop_server_env(saved)
        end
    end
end

@testset "fly suspend and image precompile" begin
    root = abspath(joinpath(@__DIR__, ".."))
    fly = read(joinpath(root, "fly.toml"), String)
    docker = read(joinpath(root, "Dockerfile"), String)
    project = read(joinpath(root, "Project.toml"), String)
    qa_project = read(joinpath(root, "qa", "Project.toml"), String)
    launcher = read(joinpath(root, "bin", "server"), String)
    @test occursin("auto_stop_machines = \"suspend\"", fly)
    @test !occursin("auto_stop_machines = \"stop\"", fly)
    memory = match(r"memory\s*=\s*\"(\d+)mb\"", fly)
    @test memory !== nothing
    @test parse(Int, memory.captures[1]) <= 2048
    @test occursin("method = \"GET\"", fly)
    @test occursin("path = \"/health\"", fly)
    @test occursin("min_machines_running = 0", fly)
    @test occursin("JULIA_CPU_TARGET=generic", docker)
    @test occursin("JULIA_DEPOT_PATH=/opt/julia", docker)
    @test occursin("Pkg.precompile()", docker)
    @test occursin("using CarolinaCodes, HTTP, LibPQ, JSON", docker)
    @test occursin("--threads=auto,1", docker)
    @test !occursin("compiled-modules=no", docker)
    @test !occursin("pkgimages=no", docker)
    @test !occursin("JULIA_PKG_PRECOMPILE_AUTO=0", docker)
    @test !occursin("compiled-modules=no", launcher)
    @test occursin("--threads=auto,1", launcher)
    @test !occursin("Aqua", project)
    @test occursin("Aqua", qa_project)
    @test !occursin("qa/", docker)
    @test !occursin("Aqua", docker)
end

# Drive the committed Gitea workflow: one prepare job, then five parallel checks.
const PROJECT_ROOT = abspath(joinpath(@__DIR__, ".."))
const CI_ENV_HELPER = joinpath(PROJECT_ROOT, "scripts", "ci-env.sh")

function gitea_job_names(yaml::AbstractString)
    parts = split(yaml, r"^jobs:"m; limit = 2)
    length(parts) == 2 || return String[]
    names = String[]
    for line in split(parts[2], '\n')
        m = match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        m === nothing || push!(names, String(m.captures[1]))
    end
    return names
end

function gitea_job_bodies(yaml::AbstractString)
    parts = split(yaml, r"^jobs:"m; limit = 2)
    length(parts) == 2 || return Dict{String,String}()
    rest = parts[2]
    bodies = Dict{String,String}()
    matches = collect(eachmatch(r"^  ([A-Za-z0-9_-]+):\s*$"m, rest))
    for (i, m) in enumerate(matches)
        name = String(m.captures[1])
        start = m.offset + length(m.match)
        stop = i < length(matches) ? matches[i+1].offset - 1 : lastindex(rest)
        bodies[name] = rest[start:stop]
    end
    return bodies
end

function job_needs(body::AbstractString)
    needs = String[]
    m = match(r"^\s+needs:\s*\[([^\]]+)\]"m, body)
    if m !== nothing
        inner = replace(m.captures[1], r"['\"]" => "")
        append!(needs, filter(!isempty, strip.(split(inner, r"\s*,\s*"))))
        return needs
    end
    m = match(r"^\s+needs:\s*\n((?:[ \t]+-[ \t]+\S+\n)+)"m, body)
    if m !== nothing
        for cap in eachmatch(r"-[ \t]+(\S+)", m.captures[1])
            push!(needs, replace(cap.captures[1], r"['\"]" => ""))
        end
        return needs
    end
    m = match(r"^\s+needs:\s*(\S+)\s*$"m, body)
    if m !== nothing
        v = replace(m.captures[1], r"['\"]" => "")
        if !isempty(v) && v != "|"
            push!(needs, v)
        end
    end
    return needs
end

function job_source_text(root::AbstractString, body::AbstractString)
    text = String(body)
    if occursin("scripts/ci-env.sh", body)
        text *= "\n" * read(joinpath(root, "scripts", "ci-env.sh"), String)
    end
    return text
end

function is_executable(path::AbstractString)
    return isfile(path) && (filemode(path) & 0o111) != 0
end

function run_ci_env(cmd::AbstractString, env::Dict{String,String})
    merged = Dict{String,String}(ENV)
    for (k, v) in env
        merged[k] = v
    end
    io = IOBuffer()
    proc = run(
        pipeline(setenv(`bash $CI_ENV_HELPER $cmd`, merged); stdout = io, stderr = io);
        wait = false,
    )
    wait(proc)
    out = String(take!(io))
    if proc.exitcode != 0
        error("ci-env.sh $(cmd) failed ($(proc.exitcode)):\n$(out)")
    end
    return out
end

function request_bytes(req::HTTP.Request)
    return req.body isa HTTP.BytesBody ? copy(req.body) : UInt8[]
end

function openssl_md5_b64(data::Vector{UInt8})
    path = tempname()
    write(path, data)
    try
        return strip(
            read(
                `bash -lc "openssl dgst -md5 -binary '$path' | openssl base64 -A"`,
                String,
            ),
        )
    finally
        rm(path; force = true)
    end
end

function openssl_md5_hex(data::AbstractString)
    path = tempname()
    write(path, data)
    try
        line = strip(read(`openssl dgst -md5 $path`, String))
        return String(split(line)[end])
    finally
        rm(path; force = true)
    end
end

mutable struct FakeArtifactStore
    token::String
    run_id::String
    pending::Dict{String,Vector{UInt8}}
    confirmed::Dict{String,Vector{UInt8}}
    filenames::Dict{String,String}
end

FakeArtifactStore(token, run_id) = FakeArtifactStore(
    token,
    run_id,
    Dict{String,Vector{UInt8}}(),
    Dict{String,Vector{UInt8}}(),
    Dict{String,String}(),
)

function split_target(target::AbstractString)
    parts = split(target, '?', limit = 2)
    path = String(parts[1])
    query = Dict{String,String}()
    if length(parts) == 2
        for pair in split(parts[2], '&')
            kv = split(pair, '=', limit = 2)
            if length(kv) == 2
                query[String(kv[1])] = String(replace(kv[2], "%2F" => "/"))
            end
        end
    end
    return path, query
end

function fake_gitea_handler(store::FakeArtifactStore)
    return function (req::HTTP.Request)
        auth = HTTP.header(req.headers, "Authorization", "")
        if !startswith(auth, "Bearer ")
            return HTTP.Response(401, "Bad authorization header")
        end
        path, query = split_target(req.target)
        host = HTTP.header(req.headers, "Host", "127.0.0.1")
        origin = "http://$(host)"
        base = "$(origin)/api/actions_pipeline/_apis/pipelines/workflows/$(store.run_id)/artifacts"
        if req.method == "POST" && endswith(path, "/artifacts")
            data = JSON.parse(String(request_bytes(req)))
            art_name = string(get(data, "Name", get(data, "name", "")))
            isempty(art_name) && return HTTP.Response(400, "missing Name")
            store.filenames[art_name] = art_name
            h = openssl_md5_hex(art_name)
            body = JSON.json(Dict("fileContainerResourceUrl" => "$(base)/$(h)/upload"))
            return HTTP.Response(200, ["Content-Type" => "application/json"], body)
        end
        if req.method == "PUT" && occursin("/upload", path)
            item = get(query, "itemPath", "")
            bytes = request_bytes(req)
            want = openssl_md5_b64(bytes)
            got = HTTP.header(req.headers, "x-actions-results-md5", "")
            got != want && return HTTP.Response(400, "md5 mismatch")
            store.pending[item] = bytes
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "{\"message\":\"success\"}",
            )
        end
        if req.method == "PATCH" && endswith(split(path, '?')[1], "/artifacts")
            art_name = get(query, "artifactName", "")
            for (item, bytes) in collect(store.pending)
                startswith(item, art_name * "/") || continue
                store.confirmed[art_name] = bytes
                store.filenames[art_name] = String(split(item, '/'; limit = 2)[end])
                delete!(store.pending, item)
            end
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "{\"message\":\"success\"}",
            )
        end
        if req.method == "GET" && endswith(path, "/artifacts")
            items = Any[]
            for (art_name, _) in store.confirmed
                h = openssl_md5_hex(art_name)
                push!(
                    items,
                    Dict(
                        "name" => art_name,
                        "fileContainerResourceUrl" => "$(base)/$(h)/download_url",
                    ),
                )
            end
            isempty(items) && return HTTP.Response(404, "not found")
            body = JSON.json(Dict("count" => length(items), "value" => items))
            return HTTP.Response(200, ["Content-Type" => "application/json"], body)
        end
        if req.method == "GET" && endswith(path, "/download_url")
            art_name = get(query, "itemPath", "")
            haskey(store.confirmed, art_name) || return HTTP.Response(404, "not found")
            filename = get(store.filenames, art_name, "prepared-env.tar.gz")
            files = [
                Dict(
                    "path" => art_name * "/" * filename,
                    "itemType" => "file",
                    "contentLocation" => "$(base)/1/download",
                ),
            ]
            body = JSON.json(Dict("value" => files))
            return HTTP.Response(200, ["Content-Type" => "application/json"], body)
        end
        if req.method == "GET" && occursin("/download", path)
            art_name = get(query, "itemPath", "")
            if occursin('/', art_name)
                art_name = String(split(art_name, '/')[1])
            end
            if !haskey(store.confirmed, art_name)
                # Helper also requests by encoded path; fall back to the only blob.
                length(store.confirmed) == 1 || return HTTP.Response(404, "not found")
                art_name = first(keys(store.confirmed))
            end
            return HTTP.Response(200, store.confirmed[art_name])
        end
        return HTTP.Response(404, "no $(path)")
    end
end

function write_prepared_fixture(ws, juliaup, depot, localdir)
    mkpath(joinpath(ws, "src"))
    write(joinpath(ws, "src", "CarolinaCodes.jl"), "module CarolinaCodes\nend\n")
    write(joinpath(ws, "Makefile"), "test:\n\ttrue\n")
    mkpath(joinpath(juliaup, "bin"))
    write(joinpath(juliaup, "bin", "julia"), "#!/bin/sh\necho julia\n")
    chmod(joinpath(juliaup, "bin", "julia"), 0o755)
    mkpath(joinpath(depot, "packages", "HTTP"))
    write(joinpath(depot, "packages", "HTTP", "src.jl"), "module HTTP\nend\n")
    mkpath(joinpath(localdir, "bin"))
    for tool in ("semgrep", "trivy", "gitleaks")
        p = joinpath(localdir, "bin", tool)
        write(p, "#!/bin/sh\necho $(tool)\n")
        chmod(p, 0o755)
    end
end

function assert_prepared_tree(ws, juliaup, depot, localdir)
    @test read(joinpath(ws, "src", "CarolinaCodes.jl"), String) ==
          "module CarolinaCodes\nend\n"
    @test read(joinpath(ws, "Makefile"), String) == "test:\n\ttrue\n"
    @test read(joinpath(depot, "packages", "HTTP", "src.jl"), String) ==
          "module HTTP\nend\n"
    @test is_executable(joinpath(juliaup, "bin", "julia"))
    @test is_executable(joinpath(localdir, "bin", "semgrep"))
    @test is_executable(joinpath(localdir, "bin", "trivy"))
    @test is_executable(joinpath(localdir, "bin", "gitleaks"))
end

@testset "gitea workflow prepare then parallel checks" begin
    root = PROJECT_ROOT
    helper = CI_ENV_HELPER
    workflow_dir = joinpath(root, ".gitea", "workflows")
    @test isdir(workflow_dir)
    @test isfile(helper)
    files = sort(
        filter(f -> endswith(f, ".yml") || endswith(f, ".yaml"), readdir(workflow_dir)),
    )
    @test !isempty(files)
    @test "checks.yml" in files
    yaml = read(joinpath(workflow_dir, "checks.yml"), String)
    @test !occursin(r"^\s*git init\b"m, yaml)
    @test !occursin("git config --global init.defaultBranch", yaml)
    @test !occursin("actions/checkout", yaml)
    @test !occursin("actions/upload-artifact", yaml)
    @test !occursin("actions/download-artifact", yaml)

    required = ["audit", "format", "gitleaks", "sast", "test"]
    jobs = gitea_job_names(yaml)
    bodies = gitea_job_bodies(yaml)
    @test "prepare" in jobs
    for name in required
        @test name in jobs
    end
    @test sort(jobs) == sort(vcat("prepare", required))

    prepare_src = job_source_text(root, bodies["prepare"])
    @test occursin("git clone", prepare_src)
    @test occursin("GITHUB_SHA", prepare_src)
    @test occursin("x-access-token", prepare_src)
    @test occursin("scripts/ci-env.sh prepare", bodies["prepare"])
    @test isempty(job_needs(bodies["prepare"]))
    @test occursin("install.julialang.org", prepare_src)
    @test occursin("default-channel 1.12", prepare_src)
    @test occursin("Pkg.instantiate", prepare_src)
    @test occursin("--project=format", prepare_src)
    @test occursin("--project=qa", prepare_src)
    @test occursin("semgrep", prepare_src)
    @test occursin("trivy", prepare_src)
    @test occursin("v0.74.0", prepare_src)
    @test occursin("gitleaks_8.30.1", prepare_src)
    @test occursin("cmd_upload", prepare_src)
    @test occursin("/api/actions_pipeline/_apis/pipelines/workflows/", prepare_src)

    @test occursin("ci-env.sh restore", yaml)
    @test occursin("prepared-env", yaml) || occursin("ci-env.sh restore", yaml)

    for name in required
        body = bodies[name]
        needs = job_needs(body)
        @test needs == ["prepare"]
        @test occursin("*restore-prepared-env", body) || occursin("ci-env.sh restore", body)
        @test occursin(Regex("make $(name)\\b"), body)
        @test !occursin("git clone", body)
        @test !occursin("apt-get", body)
        @test !occursin("install.julialang.org", body)
        @test !occursin("pip install", body)
        @test !occursin("contrib/install.sh", body)
        @test !occursin("gitleaks/releases", body)
        for other in required
            other == name && continue
            @test !occursin(Regex("^\\s+needs:\\s*$(other)\\s*\$", "m"), body)
        end
    end
end

@testset "ci-env pack/unpack roundtrip" begin
    @test isfile(CI_ENV_HELPER)
    root = mktempdir()
    ws = joinpath(root, "ws")
    juliaup = joinpath(root, "juliaup")
    depot = joinpath(root, "depot")
    localdir = joinpath(root, "local")
    write_prepared_fixture(ws, juliaup, depot, localdir)
    tarpath = joinpath(root, "prepared-env.tar.gz")
    env = Dict(
        "GITHUB_WORKSPACE" => ws,
        "JULIAUP_DEPOT_PATH" => juliaup,
        "JULIA_DEPOT_PATH" => depot,
        "CI_LOCAL_DIR" => localdir,
        "CI_ENV_TAR" => tarpath,
        "CI_ENV_ARTIFACT_NAME" => "prepared-env",
        "CI_ENV_SKIP_INSTALL" => "1",
    )
    out = run_ci_env("pack", env)
    @test occursin("packed", out)
    @test isfile(tarpath)
    @test filesize(tarpath) > 0

    ws2 = joinpath(root, "ws2")
    juliaup2 = joinpath(root, "juliaup2")
    depot2 = joinpath(root, "depot2")
    localdir2 = joinpath(root, "local2")
    env2 = Dict(
        "GITHUB_WORKSPACE" => ws2,
        "JULIAUP_DEPOT_PATH" => juliaup2,
        "JULIA_DEPOT_PATH" => depot2,
        "CI_LOCAL_DIR" => localdir2,
        "CI_ENV_TAR" => tarpath,
        "CI_ENV_ARTIFACT_NAME" => "prepared-env",
        "CI_ENV_SKIP_INSTALL" => "1",
    )
    out2 = run_ci_env("unpack", env2)
    @test occursin("restored", out2)
    assert_prepared_tree(ws2, juliaup2, depot2, localdir2)
end

@testset "ci-env artifact API roundtrip" begin
    root = mktempdir()
    ws = joinpath(root, "ws")
    juliaup = joinpath(root, "juliaup")
    depot = joinpath(root, "depot")
    localdir = joinpath(root, "local")
    write_prepared_fixture(ws, juliaup, depot, localdir)
    tarpath = joinpath(root, "prepared-env.tar.gz")

    store = FakeArtifactStore("test-token", "42")
    server = HTTP.serve!(fake_gitea_handler(store), "127.0.0.1", 0; listenany = true)
    try
        port = 0
        for _ = 1:100
            port = HTTP.port(server)
            port != 0 && break
            sleep(0.01)
        end
        @test port != 0
        origin = "http://127.0.0.1:$(port)"
        env = Dict(
            "GITHUB_WORKSPACE" => ws,
            "JULIAUP_DEPOT_PATH" => juliaup,
            "JULIA_DEPOT_PATH" => depot,
            "CI_LOCAL_DIR" => localdir,
            "CI_ENV_TAR" => tarpath,
            "CI_ENV_ARTIFACT_NAME" => "prepared-env",
            "CI_ENV_SKIP_INSTALL" => "1",
            "ACTIONS_RUNTIME_URL" => origin * "/api/actions_pipeline/",
            "ACTIONS_RUNTIME_TOKEN" => "test-token",
            "GITHUB_RUN_ID" => "42",
            "GITHUB_SERVER_URL" => origin,
        )
        out = run_ci_env("prepare", env)
        @test occursin("uploaded artifact", out)
        @test haskey(store.confirmed, "prepared-env")

        ws2 = joinpath(root, "restored")
        juliaup2 = joinpath(root, "juliaup-restored")
        depot2 = joinpath(root, "depot-restored")
        localdir2 = joinpath(root, "local-restored")
        tar2 = joinpath(root, "downloaded.tar.gz")
        env2 = Dict(
            "GITHUB_WORKSPACE" => ws2,
            "JULIAUP_DEPOT_PATH" => juliaup2,
            "JULIA_DEPOT_PATH" => depot2,
            "CI_LOCAL_DIR" => localdir2,
            "CI_ENV_TAR" => tar2,
            "CI_ENV_ARTIFACT_NAME" => "prepared-env",
            "CI_ENV_SKIP_INSTALL" => "1",
            "ACTIONS_RUNTIME_URL" => origin * "/api/actions_pipeline/",
            "ACTIONS_RUNTIME_TOKEN" => "test-token",
            "GITHUB_RUN_ID" => "42",
            "GITHUB_SERVER_URL" => origin,
        )
        out2 = run_ci_env("restore", env2)
        @test occursin("restored", out2)
        assert_prepared_tree(ws2, juliaup2, depot2, localdir2)
        @test is_executable(joinpath(juliaup2, "bin", "julia"))
    finally
        close(server)
    end
end
