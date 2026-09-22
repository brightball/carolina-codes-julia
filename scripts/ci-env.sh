#!/usr/bin/env bash
# Prepare/restore the Gitea CI workspace without Node.
#
# act_runner starts a new container per job, so the only share is a run
# artifact. Official Node artifact actions treat Gitea as GHES and abort.
# This helper talks to /api/actions_pipeline/_apis/pipelines/workflows/{run_id}/artifacts
# with curl, then packs the cloned workspace plus Julia depot, juliaup, and
# tool binaries (Semgrep, Trivy, gitleaks).
set -euo pipefail

ARTIFACT_NAME="${CI_ENV_ARTIFACT_NAME:-prepared-env}"
TAR_PATH="${CI_ENV_TAR:-/tmp/prepared-env.tar.gz}"

json_string() {
  key="$1"
  file="$2"
  tr -d '\n' <"$file" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

artifact_token() {
  t="${ACTIONS_RUNTIME_TOKEN:-${GITHUB_TOKEN:-${GITEA_TOKEN:-}}}"
  if [ -z "$t" ]; then
    echo "missing artifact token (ACTIONS_RUNTIME_TOKEN/GITHUB_TOKEN)" >&2
    exit 1
  fi
  printf '%s' "$t"
}

artifact_base() {
  if [ -n "${ACTIONS_RUNTIME_URL:-}" ]; then
    printf '%s' "${ACTIONS_RUNTIME_URL%/}"
    return
  fi
  if [ -z "${GITHUB_SERVER_URL:-}" ]; then
    echo "missing ACTIONS_RUNTIME_URL or GITHUB_SERVER_URL" >&2
    exit 1
  fi
  printf '%s' "${GITHUB_SERVER_URL%/}/api/actions_pipeline"
}

rewrite_runtime_url() {
  url="$1"
  case "$url" in
    *_apis/*)
      suffix="${url#*_apis/}"
      printf '%s/_apis/%s' "$(artifact_base)" "$suffix"
      ;;
    /*)
      printf '%s%s' "$(artifact_base)" "${url#/api/actions_pipeline}"
      ;;
    *)
      printf '%s' "$url"
      ;;
  esac
}

md5_b64() {
  openssl dgst -md5 -binary "$1" | openssl base64 -A
}

workspace_dir() {
  printf '%s' "${GITHUB_WORKSPACE:-$(pwd)}"
}

juliaup_dir() {
  printf '%s' "${JULIAUP_DEPOT_PATH:-${HOME}/.juliaup}"
}

julia_depot() {
  if [ -n "${JULIA_DEPOT_PATH:-}" ]; then
    printf '%s' "${JULIA_DEPOT_PATH%%:*}"
    return
  fi
  printf '%s' "${HOME}/.julia"
}

local_dir() {
  printf '%s' "${CI_LOCAL_DIR:-${HOME}/.local}"
}

redact_git_remote() {
  ws="$(workspace_dir)"
  if [ -d "${ws}/.git" ] && [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    git -C "$ws" remote set-url origin "${GITHUB_SERVER_URL%/}/${GITHUB_REPOSITORY}" 2>/dev/null || true
  fi
}

cmd_install() {
  echo "installing Julia 1.12, Semgrep, Trivy 0.74.0, gitleaks 8.30.1, and instantiating project deps"
  ws="$(workspace_dir)"
  cd "$ws"

  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -qq && apt-get install -y --no-install-recommends \
        libpq5 make ca-certificates curl python3 python3-pip tar gzip git openssl
    else
      sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends \
        libpq5 make ca-certificates curl python3 python3-pip tar gzip git openssl
    fi
  fi

  curl -fsSL https://install.julialang.org | sh -s -- --yes --default-channel 1.12
  export PATH="$(juliaup_dir)/bin:${PATH}"
  julia --project=. -e 'using Pkg; Pkg.instantiate()'
  julia --project=format -e 'using Pkg; Pkg.instantiate()'
  julia --project=qa -e 'using Pkg; Pkg.instantiate()'

  python3 -m pip install --user semgrep || python3 -m pip install --user --break-system-packages semgrep

  bin="$(local_dir)/bin"
  mkdir -p "$bin"
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b "$bin" v0.74.0
  curl -sSL https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
    | tar -xz -C "$bin" gitleaks
  chmod +x "$bin/gitleaks" "$bin/trivy" 2>/dev/null || true
  if command -v make >/dev/null 2>&1; then
    cp "$(command -v make)" "$bin/make" 2>/dev/null || true
  fi
}

cmd_pack() {
  ws="$(workspace_dir)"
  ju="$(juliaup_dir)"
  depot="$(julia_depot)"
  localp="$(local_dir)"
  redact_git_remote
  (
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/workspace" "$stage/juliaup" "$stage/julia-depot" "$stage/local"

    if [ -d "$ws" ]; then
      tar -C "$ws" --exclude=./.git -cf - . | tar -C "$stage/workspace" -xf -
    fi
    if [ -d "$ju" ]; then
      tar -C "$ju" -cf - . | tar -C "$stage/juliaup" -xf -
    fi
    if [ -d "$depot" ]; then
      tar -C "$depot" --exclude=./logs -cf - . | tar -C "$stage/julia-depot" -xf -
    fi
    if [ -d "$localp" ]; then
      tar -C "$localp" -cf - . | tar -C "$stage/local" -xf -
    fi

    mkdir -p "$(dirname "$TAR_PATH")"
    tar -C "$stage" -czf "$TAR_PATH" workspace juliaup julia-depot local
  )
  echo "packed $TAR_PATH"
}

cmd_unpack() {
  ws="$(workspace_dir)"
  ju="$(juliaup_dir)"
  depot="$(julia_depot)"
  localp="$(local_dir)"
  if [ ! -f "$TAR_PATH" ]; then
    echo "missing tarball $TAR_PATH" >&2
    exit 1
  fi
  (
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT
    tar -C "$stage" -xzf "$TAR_PATH" --no-same-owner
    mkdir -p "$ws" "$ju" "$depot" "$localp"
    if [ -d "$stage/workspace" ]; then
      tar -C "$stage/workspace" -cf - . | tar -C "$ws" -xf -
    fi
    if [ -d "$stage/juliaup" ]; then
      tar -C "$stage/juliaup" -cf - . | tar -C "$ju" -xf -
    fi
    if [ -d "$stage/julia-depot" ]; then
      tar -C "$stage/julia-depot" -cf - . | tar -C "$depot" -xf -
    fi
    if [ -d "$stage/local" ]; then
      tar -C "$stage/local" -cf - . | tar -C "$localp" -xf -
    fi
  )
  echo "restored workspace=$ws juliaup=$ju depot=$depot local=$localp"
}

cmd_upload() {
  if [ ! -f "$TAR_PATH" ]; then
    echo "missing tarball $TAR_PATH" >&2
    exit 1
  fi
  if [ -z "${GITHUB_RUN_ID:-}" ]; then
    echo "missing GITHUB_RUN_ID" >&2
    exit 1
  fi
  token="$(artifact_token)"
  base="$(artifact_base)"
  create_url="${base}/_apis/pipelines/workflows/${GITHUB_RUN_ID}/artifacts?api-version=6.0-preview"
  resp="$(mktemp)"
  curl -fsS -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -X POST --data "{\"Type\":\"actions_storage\",\"Name\":\"${ARTIFACT_NAME}\"}" \
    "$create_url" -o "$resp"
  upload_url="$(json_string fileContainerResourceUrl "$resp")"
  rm -f "$resp"
  if [ -z "$upload_url" ]; then
    echo "artifact create did not return fileContainerResourceUrl" >&2
    exit 1
  fi
  upload_url="$(rewrite_runtime_url "$upload_url")"
  size="$(wc -c <"$TAR_PATH" | tr -d ' ')"
  md5="$(md5_b64 "$TAR_PATH")"
  filename="$(basename "$TAR_PATH")"
  put_url="${upload_url}?itemPath=${ARTIFACT_NAME}%2F${filename}"
  curl -fsS -H "Authorization: Bearer ${token}" \
    -H "x-actions-results-md5: ${md5}" \
    -H "x-tfs-filelength: ${size}" \
    -H "content-range: bytes 0-$((size - 1))/${size}" \
    -X PUT --data-binary "@${TAR_PATH}" \
    "$put_url" -o /dev/null
  curl -fsS -H "Authorization: Bearer ${token}" \
    -X PATCH \
    "${base}/_apis/pipelines/workflows/${GITHUB_RUN_ID}/artifacts?api-version=6.0-preview&artifactName=${ARTIFACT_NAME}" \
    -o /dev/null
  echo "uploaded artifact ${ARTIFACT_NAME}"
}

cmd_download() {
  if [ -z "${GITHUB_RUN_ID:-}" ]; then
    echo "missing GITHUB_RUN_ID" >&2
    exit 1
  fi
  token="$(artifact_token)"
  base="$(artifact_base)"
  list_url="${base}/_apis/pipelines/workflows/${GITHUB_RUN_ID}/artifacts?api-version=6.0-preview"
  resp="$(mktemp)"
  curl -fsS -H "Authorization: Bearer ${token}" "$list_url" -o "$resp"
  container_url="$(json_string fileContainerResourceUrl "$resp")"
  rm -f "$resp"
  if [ -z "$container_url" ]; then
    echo "artifact list did not return fileContainerResourceUrl" >&2
    exit 1
  fi
  container_url="$(rewrite_runtime_url "$container_url")"
  files="$(mktemp)"
  curl -fsS -H "Authorization: Bearer ${token}" \
    "${container_url}?itemPath=${ARTIFACT_NAME}" -o "$files"
  content_url="$(json_string contentLocation "$files")"
  item_path="$(json_string path "$files")"
  rm -f "$files"
  if [ -z "$content_url" ]; then
    echo "artifact download_url did not return contentLocation" >&2
    exit 1
  fi
  content_url="$(rewrite_runtime_url "$content_url")"
  mkdir -p "$(dirname "$TAR_PATH")"
  encoded_path="$(printf '%s' "$item_path" | sed 's|/|%2F|g')"
  curl -fsS -H "Authorization: Bearer ${token}" \
    "${content_url}?itemPath=${encoded_path}" -o "$TAR_PATH"
  echo "downloaded $TAR_PATH"
}

cmd_prepare() {
  if [ "${CI_ENV_SKIP_INSTALL:-}" != "1" ]; then
    cmd_install
  fi
  cmd_pack
  cmd_upload
}

cmd_restore() {
  echo "restoring prepared environment"
  cmd_download
  cmd_unpack
  export PATH="$(local_dir)/bin:$(juliaup_dir)/bin:${PATH}"
  export JULIAUP_DEPOT_PATH="$(juliaup_dir)"
  export JULIA_DEPOT_PATH="$(julia_depot)"
}

usage() {
  echo "usage: $0 prepare|restore|install|pack|unpack|upload|download" >&2
  exit 2
}

cmd="${1:-}"
case "$cmd" in
  prepare) cmd_prepare ;;
  restore) cmd_restore ;;
  install) cmd_install ;;
  pack) cmd_pack ;;
  unpack) cmd_unpack ;;
  upload) cmd_upload ;;
  download) cmd_download ;;
  *) usage ;;
esac
