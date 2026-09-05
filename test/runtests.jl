using Test
using JSON
using CarolinaCodes

function fake_query(sql::AbstractString, args)
    if occursin("FROM v1_speakers WHERE slug =", sql)
        if !isempty(args) && string(args[1]) == "diana-pham"
            return [Dict{String,Any}(
                "slug" => "diana-pham",
                "first_name" => "Diana",
                "last_name" => "Pham",
                "name" => "Diana Pham",
            )]
        end
        return Dict{String,Any}[]
    end
    if occursin("FROM v1_speakers", sql)
        return [Dict{String,Any}(
            "slug" => "diana-pham",
            "first_name" => "Diana",
            "last_name" => "Pham",
            "name" => "Diana Pham",
        )]
    end
    if occursin("FROM v1_talks", sql)
        return [Dict{String,Any}(
            "slug" => "talk",
            "title" => "Talk",
            "speaker_slug" => "diana-pham",
            "year" => 2026,
            "languages" => "{php}",
            "topics" => "{development}",
        )]
    end
    if occursin("FROM v1_year_sponsors", sql)
        if length(args) >= 2 && string(args[2]) == "missing-sponsor"
            return Dict{String,Any}[]
        end
        return [Dict{String,Any}(
            "slug" => "flywheel",
            "name" => "Flywheel",
            "tier" => "platinum",
            "year" => 2026,
        )]
    end
    if occursin("FROM v1_sponsors WHERE slug", sql)
        return Dict{String,Any}[]
    end
    if occursin("FROM v1_sponsors", sql)
        return [Dict{String,Any}(
            "slug" => "flywheel",
            "name" => "Flywheel",
            "tier" => "platinum",
            "year" => 2026,
        )]
    end
    if occursin("FROM v1_years", sql)
        return [Dict{String,Any}(
            "year" => 2026,
            "slug" => "2026",
            "name" => "Carolina Code Conference 2026",
            "status" => "past",
        )]
    end
    if occursin("FROM v1_sponsorships", sql)
        return Dict{String,Any}[]
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
