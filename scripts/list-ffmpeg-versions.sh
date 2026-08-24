#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-config/project.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Configuration file not found: $CONFIG_FILE" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${FFMPEG_UPSTREAM_URL:?FFMPEG_UPSTREAM_URL is required}"
: "${FFMPEG_MIN_VERSION:?FFMPEG_MIN_VERSION is required}"

if ! [[ "$FFMPEG_MIN_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "FFMPEG_MIN_VERSION must match X.Y or X.Y.Z" >&2
  exit 2
fi

version_ge() {
  local lhs="$1" rhs="$2"
  local l_major l_minor l_patch r_major r_minor r_patch
  IFS='.' read -r l_major l_minor l_patch <<< "$lhs"
  IFS='.' read -r r_major r_minor r_patch <<< "$rhs"
  l_patch="${l_patch:-0}"
  r_patch="${r_patch:-0}"

  (( l_major > r_major )) && return 0
  (( l_major < r_major )) && return 1
  (( l_minor > r_minor )) && return 0
  (( l_minor < r_minor )) && return 1
  (( l_patch >= r_patch ))
}

mapfile -t tags < <(
  git ls-remote --tags --refs "$FFMPEG_UPSTREAM_URL" 'refs/tags/n*' \
    | awk '{print $2}' \
    | sed 's#^refs/tags/##' \
    | grep -E '^n[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | sort -Vu
)

for tag in "${tags[@]}"; do
  version="${tag#n}"
  if version_ge "$version" "$FFMPEG_MIN_VERSION"; then
    printf '%s\n' "$version"
  fi
done
