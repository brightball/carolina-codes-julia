FROM julia:1.12-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Project.toml Manifest.toml ./
COPY src ./src
COPY server.jl ./
ENV JULIA_DEPOT_PATH=/opt/julia
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
ENV PORT=8080
EXPOSE 8080
CMD ["julia", "--project=.", "server.jl"]
