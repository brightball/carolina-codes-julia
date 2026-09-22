"""Carolina Code Conference polyglot API — Julia + HTTP.jl."""
module CarolinaCodes

export handle_get, http_handler, register_with_elixir, reset_counts
export LANGUAGE, FRAMEWORK, SQL_COUNT, CONNECT_COUNT, QUERY_HOOK

using HTTP
using JSON
using LibPQ

const LANGUAGE = "Julia"
const FRAMEWORK = "HTTP.jl"
const API_VERSION = "0.2.0"
const CREATED_YEAR = 2026
const SCHEMA_VERSION = 1

const ENDPOINTS = [
    Dict("method" => "GET", "path" => "/", "query" => String[]),
    Dict("method" => "GET", "path" => "/health", "query" => String[]),
    Dict("method" => "GET", "path" => "/v1/years", "query" => String[]),
    Dict("method" => "GET", "path" => "/v1/speakers", "query" => ["year"]),
    Dict("method" => "GET", "path" => "/v1/speakers/:slug", "query" => String[]),
    Dict("method" => "GET", "path" => "/v1/speakers/:year/:slug", "query" => String[]),
    Dict("method" => "GET", "path" => "/v1/sponsors", "query" => ["year"]),
    Dict("method" => "GET", "path" => "/v1/sponsors/:slug", "query" => String[]),
    Dict("method" => "GET", "path" => "/v1/sponsors/:year/:slug", "query" => String[]),
]

const SPEAKER_COLS =
    "slug, first_name, last_name, name, tagline, bio, company, location, " *
    "photo_path, twitter_url, linkedin_url, website_url, github_url, featured"
const YEAR_SPONSOR_COLS =
    "slug, name, website, logo_path, description, blurb, tier, featured, year, " *
    "twitter_url, linkedin_url, youtube_url, instagram_url, facebook_url"
const SPONSOR_COLS =
    "slug, name, website, logo_path, description, twitter_url, linkedin_url, " *
    "youtube_url, instagram_url, facebook_url"
const TALK_COLS = "slug, title, description, format, youtube_id, year, speaker_slug, languages, topics"

const SQL_COUNT = Ref(0)
const CONNECT_COUNT = Ref(0)
const QUERY_HOOK = Ref{Any}(nothing)
const CONNECT_HOOK = Ref{Any}(nothing)
const CONN = Ref{Any}(nothing)
const DB_LOCK = ReentrantLock()
const REGISTRATION_TASK = Ref{Any}(nothing)

language_version() = string(VERSION)

function reset_counts()
    SQL_COUNT[] = 0
    CONNECT_COUNT[] = 0
end

function env(name::AbstractString, default::AbstractString = "")
    v = get(ENV, name, default)
    return isempty(v) ? default : v
end

function dsn()
    raw = env("DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev")
    if !occursin("sslmode=", raw)
        raw *= (occursin("?", raw) ? "&" : "?") * "sslmode=disable"
    end
    return raw
end

function listen_port()
    return parse(Int, env("PORT", "4025"))
end

function identity()
    return Dict{String,Any}(
        "language" => LANGUAGE,
        "language_version" => language_version(),
        "api_version" => API_VERSION,
        "framework" => FRAMEWORK,
        "created_year" => CREATED_YEAR,
        "schema_version" => SCHEMA_VERSION,
        "endpoints" => ENDPOINTS,
    )
end

function pg_text_array(value)
    if value === missing || value === nothing
        return String[]
    end
    if value isa AbstractVector
        return String[string(x) for x in value if x !== missing && string(x) != ""]
    end
    stripped = strip(string(value))
    if stripped in ("", "{}", "[]")
        return String[]
    end
    if startswith(stripped, "{") && endswith(stripped, "}")
        stripped = stripped[2:(end-1)]
    elseif startswith(stripped, "[") && endswith(stripped, "]")
        stripped = stripped[2:(end-1)]
    end
    out = String[]
    for part in split(stripped, ',')
        p = strip(part, [' ', '\t', '"', '\''])
        if !isempty(p)
            push!(out, p)
        end
    end
    return out
end

function clean(row)
    row === nothing && return nothing
    out = Dict{String,Any}()
    pairs_iter = row isa AbstractDict ? row : pairs(row)
    for (k, v) in pairs_iter
        key = string(k)
        if v === missing
            continue
        elseif key in ("languages", "topics")
            out[key] = pg_text_array(v)
        elseif key == "year"
            out[key] = Int(v)
        else
            out[key] = v isa AbstractString ? String(v) : v
        end
    end
    return out
end

"""True when `conn` can run another query. Closed and `CONNECTION_BAD` handles are not reused."""
function connection_usable(conn)::Bool
    conn === nothing && return false
    opened = try
        isopen(conn)
    catch
        false
    end
    opened || return false
    conn isa LibPQ.Connection || return true
    return try
        LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
    catch
        false
    end
end

function discard_conn(conn)
    lock(DB_LOCK) do
        if CONN[] === conn
            CONN[] = nothing
        end
    end
    conn === nothing && return nothing
    try
        close(conn)
    catch
    end
    return nothing
end

function open_connection()
    CONNECT_COUNT[] += 1
    hook = CONNECT_HOOK[]
    if hook !== nothing
        return hook()
    end
    return LibPQ.Connection(dsn())
end

function ensure_conn()
    lock(DB_LOCK) do
        current = CONN[]
        if connection_usable(current)
            return current
        end
        if current !== nothing
            CONN[] = nothing
            try
                close(current)
            catch
            end
        end
        CONN[] = open_connection()
        return CONN[]
    end
end

function db_query(sql::AbstractString, args = Any[])
    SQL_COUNT[] += 1
    hook = QUERY_HOOK[]
    if hook !== nothing
        return hook(sql, args)
    end
    conn = ensure_conn()
    try
        result = isempty(args) ? execute(conn, sql) : execute(conn, sql, args)
        names = LibPQ.column_names(result)
        rows = Dict{String,Any}[]
        for r in result
            raw = Dict{String,Any}()
            for (i, name) in enumerate(names)
                raw[name] = r[i]
            end
            push!(rows, clean(raw))
        end
        close(result)
        return rows
    catch
        discard_conn(conn)
        rethrow()
    end
end

function db_query_one(sql::AbstractString, args = Any[])
    rows = db_query(sql, args)
    return isempty(rows) ? nothing : rows[1]
end

function uniq_tags(talks, key)
    seen = Set{String}()
    out = String[]
    for talk in talks
        for val in pg_text_array(get(talk, key, String[]))
            if !(val in seen)
                push!(seen, val)
                push!(out, val)
            end
        end
    end
    return out
end

function talks_for(slug::AbstractString, year = nothing)
    if year === nothing
        return db_query(
            "SELECT $TALK_COLS FROM v1_talks WHERE speaker_slug = \$1 ORDER BY year DESC",
            [slug],
        )
    end
    return db_query(
        "SELECT $TALK_COLS FROM v1_talks WHERE speaker_slug = \$1 AND year = \$2 ORDER BY year DESC",
        [slug, year],
    )
end

function talk_years(slug::AbstractString)
    rows = db_query(
        "SELECT DISTINCT year FROM v1_talks WHERE speaker_slug = \$1 ORDER BY year DESC",
        [slug],
    )
    return [Int(r["year"]) for r in rows]
end

function sponsor_years(slug::AbstractString)
    rows = db_query(
        "SELECT DISTINCT year FROM v1_sponsorships WHERE sponsor_slug = \$1 ORDER BY year DESC",
        [slug],
    )
    return [Int(r["year"]) for r in rows]
end

function load_talks_for_year(year::Integer)
    rows = db_query(
        "SELECT $TALK_COLS FROM v1_talks WHERE year = \$1 ORDER BY speaker_slug, year DESC",
        [year],
    )
    out = Dict{String,Vector{Dict{String,Any}}}()
    for talk in rows
        slug = string(get(talk, "speaker_slug", ""))
        push!(get!(out, slug, Dict{String,Any}[]), talk)
    end
    return out
end

function load_years_for_slugs(slugs)
    isempty(slugs) && return Dict{String,Vector{Int}}()
    rows = db_query(
        "SELECT DISTINCT speaker_slug, year FROM v1_talks " *
        "WHERE speaker_slug = ANY(\$1) ORDER BY speaker_slug, year DESC",
        [collect(slugs)],
    )
    out = Dict{String,Vector{Int}}()
    for row in rows
        slug = string(row["speaker_slug"])
        push!(get!(out, slug, Int[]), Int(row["year"]))
    end
    return out
end

function attach_year_tags(speakers, year::Integer)
    isempty(speakers) && return speakers
    slugs = [sp["slug"] for sp in speakers]
    talks_by = load_talks_for_year(year)
    years_by = load_years_for_slugs(slugs)
    for sp in speakers
        slug = sp["slug"]
        talks = get(talks_by, slug, Dict{String,Any}[])
        years = get(years_by, slug, Int[])
        sp["year"] = year
        sp["talks"] = talks
        sp["languages"] = uniq_tags(talks, "languages")
        sp["topics"] = uniq_tags(talks, "topics")
        sp["years"] = years
    end
    return speakers
end

function list_speakers(year = nothing)
    if year === nothing
        return db_query(
            "SELECT $SPEAKER_COLS FROM v1_speakers ORDER BY last_name, first_name",
        )
    end
    rows = db_query(
        "SELECT $SPEAKER_COLS FROM v1_speakers WHERE slug IN " *
        "(SELECT speaker_slug FROM v1_talks WHERE year = \$1) ORDER BY last_name, first_name",
        [year],
    )
    return attach_year_tags(rows, year)
end

function normalize_path(path::AbstractString)
    isempty(path) && return "/"
    if length(path) > 1 && endswith(path, '/')
        return path[1:(end-1)]
    end
    return path
end

function is_year(s::AbstractString)
    return !isempty(s) && all(isdigit, s)
end

"""Shipped GET router. Tests call this without a live listen."""
function handle_get(path::AbstractString, year_query::AbstractString = "")
    path = normalize_path(path)
    parts = [p for p in split(path, '/') if !isempty(p)]

    if path == "/health"
        return 200, Dict{String,Any}("status" => "ok")
    end
    if path == "/"
        return 200, identity()
    end
    if path == "/v1/years"
        return 200,
        Dict{String,Any}(
            "data" => db_query(
                "SELECT year, slug, name, status FROM v1_years ORDER BY year DESC",
            ),
        )
    end
    if path == "/v1/speakers"
        year = isempty(year_query) ? nothing : parse(Int, year_query)
        return 200, Dict{String,Any}("data" => list_speakers(year))
    end
    if length(parts) == 4 && parts[1] == "v1" && parts[2] == "speakers" && is_year(parts[3])
        year = parse(Int, parts[3])
        slug = parts[4]
        speaker =
            db_query_one("SELECT $SPEAKER_COLS FROM v1_speakers WHERE slug = \$1", [slug])
        speaker === nothing && return 404, Dict{String,Any}("error" => "not_found")
        talks = talks_for(slug, year)
        isempty(talks) && return 404, Dict{String,Any}("error" => "not_found")
        years = talk_years(slug)
        speaker["year"] = year
        speaker["years"] = years
        speaker["other_years"] = [y for y in years if y != year]
        speaker["talks"] = talks
        speaker["languages"] = uniq_tags(talks, "languages")
        speaker["topics"] = uniq_tags(talks, "topics")
        return 200, Dict{String,Any}("data" => speaker)
    end
    if length(parts) == 3 && parts[1] == "v1" && parts[2] == "speakers"
        slug = parts[3]
        speaker =
            db_query_one("SELECT $SPEAKER_COLS FROM v1_speakers WHERE slug = \$1", [slug])
        speaker === nothing && return 404, Dict{String,Any}("error" => "not_found")
        speaker["talks"] = talks_for(slug)
        speaker["years"] = talk_years(slug)
        return 200, Dict{String,Any}("data" => speaker)
    end
    if path == "/v1/sponsors"
        if !isempty(year_query)
            rows = db_query(
                "SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = \$1 ORDER BY name",
                [parse(Int, year_query)],
            )
        else
            rows = db_query("SELECT $SPONSOR_COLS FROM v1_sponsors ORDER BY name")
        end
        return 200, Dict{String,Any}("data" => rows)
    end
    if length(parts) == 4 && parts[1] == "v1" && parts[2] == "sponsors" && is_year(parts[3])
        year = parse(Int, parts[3])
        slug = parts[4]
        row = db_query_one(
            "SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = \$1 AND slug = \$2",
            [year, slug],
        )
        row === nothing && return 404, Dict{String,Any}("error" => "not_found")
        years = sponsor_years(slug)
        row["years"] = years
        row["other_years"] = [y for y in years if y != year]
        return 200, Dict{String,Any}("data" => row)
    end
    if length(parts) == 3 && parts[1] == "v1" && parts[2] == "sponsors"
        slug = parts[3]
        row = db_query_one("SELECT $SPONSOR_COLS FROM v1_sponsors WHERE slug = \$1", [slug])
        row === nothing && return 404, Dict{String,Any}("error" => "not_found")
        row["sponsorships"] =
            db_query("SELECT * FROM v1_sponsorships WHERE sponsor_slug = \$1", [slug])
        return 200, Dict{String,Any}("data" => row)
    end
    return 404, Dict{String,Any}("error" => "not_found")
end

function request_path(target::AbstractString)
    qpos = findfirst(==('?'), target)
    qpos === nothing && return String(target)
    return String(SubString(target, 1, prevind(target, qpos)))
end

function query_param(target::AbstractString, name::AbstractString)
    qpos = findfirst(==('?'), target)
    qpos === nothing && return ""
    qs = SubString(target, nextind(target, qpos))
    for part in split(qs, '&')
        eq = findfirst(==('='), part)
        key = eq === nothing ? String(part) : String(SubString(part, 1, prevind(part, eq)))
        if key == name
            return eq === nothing ? "" : String(SubString(part, nextind(part, eq)))
        end
    end
    return ""
end

function http_handler(req::HTTP.Request)
    try
        if req.method != "GET"
            body = JSON.json(Dict("error" => "not_found"))
            return HTTP.Response(404, ["Content-Type" => "application/json"], body)
        end
        status, payload =
            handle_get(request_path(req.target), query_param(req.target, "year"))
        return HTTP.Response(
            status,
            ["Content-Type" => "application/json"],
            JSON.json(payload),
        )
    catch e
        println(stderr, "handler error: ", e)
        showerror(stderr, e, catch_backtrace())
        println(stderr)
        return HTTP.Response(
            500,
            ["Content-Type" => "application/json"],
            JSON.json(Dict("error" => "internal")),
        )
    end
end

function register_with_elixir()
    url = env("CAROLINA_URL")
    token = env("POLYGLOT_REGISTER_TOKEN")
    if isempty(url) || isempty(token)
        return
    end
    port = env("PORT", "4025")
    base = env("PUBLIC_BASE_URL", "http://127.0.0.1:$port")
    body = identity()
    body["base_url"] = base
    target = rstrip(url, '/') * "/internal/api-endpoints/register"
    try
        resp = HTTP.post(
            target,
            ["Authorization" => "Bearer $token", "Content-Type" => "application/json"],
            JSON.json(body);
            connect_timeout = 5,
            read_idle_timeout = 5,
            retry = false,
            status_exception = false,
        )
        println(stderr, "registered with elixir: $(resp.status)")
    catch e
        println(stderr, "register: failed $e")
    end
end

"""Start CMS registration off the accept loop. A slow or black-holed Elixir host must not gate `/health`."""
function schedule_registration()
    url = env("CAROLINA_URL")
    token = env("POLYGLOT_REGISTER_TOKEN")
    if isempty(url) || isempty(token)
        REGISTRATION_TASK[] = nothing
        return nothing
    end
    # Default thread pool, not `:interactive`. HTTP.serve! accepts on the
    # interactive pool (`--threads=auto,1`), so this post cannot stall it.
    REGISTRATION_TASK[] = Threads.@spawn register_with_elixir()
    return REGISTRATION_TASK[]
end

function run_server(; block::Bool = true)
    port = listen_port()
    server = HTTP.serve!(http_handler, "::", port; reuseaddr = true)
    bound = HTTP.port(server)
    println("carolina-codes-julia listening on [::]:$bound")
    schedule_registration()
    block && wait(server)
    return server
end

precompile(handle_get, (String,))
precompile(handle_get, (String, String))
precompile(http_handler, (HTTP.Request{HTTP.EmptyBody},))
precompile(register_with_elixir, ())
precompile(identity, ())
precompile(connection_usable, (Any,))
precompile(ensure_conn, ())

end # module
