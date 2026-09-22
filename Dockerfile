FROM julia:1.12-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Project.toml Manifest.toml ./
COPY src ./src
COPY server.jl ./
ENV JULIA_DEPOT_PATH=/opt/julia
ENV JULIA_CPU_TARGET=generic
RUN julia --threads=auto,1 --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using CarolinaCodes, HTTP, LibPQ, JSON; CarolinaCodes.handle_get("/health"); CarolinaCodes.handle_get("/")'
ENV PORT=8080
EXPOSE 8080
CMD ["julia", "--threads=auto,1", "--project=.", "server.jl"]
