FROM julia:1.12-bookworm
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates libpq5 make \
 && rm -rf /var/lib/apt/lists/*
ENV JULIA_DEPOT_PATH=/opt/julia JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_CPU_TARGET=generic
