# scripts/detect-ffmpeg-version.sh
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
: "${FFMPEG_MIN_MAJOR:?FFMPEG_MIN_MAJOR is required}"

if ! [[ "$FFMPEG_MIN_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "FFMPEG_MIN_MAJOR must be an integer" >&2
    exit 2
fi

emit_output() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

mapfile -t eligible_tags < <(
    git ls-remote --tags --refs "$FFMPEG_UPSTREAM_URL" 'refs/tags/n*' \
        | awk '{print $2}' \
        | sed 's#^refs/tags/##' \
        | grep -E '^n[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | awk -F'[n.]' -v min_major="$FFMPEG_MIN_MAJOR" '$2 >= min_major' \
        | sort -Vu
)

if (( ${#eligible_tags[@]} == 0 )); then
    emit_output found false
    emit_output tag ""
    emit_output version ""
    emit_output commit ""
    exit 0
fi

latest_tag="${eligible_tags[-1]}"
version="${latest_tag#n}"

# Prefer the peeled commit for annotated tags; fall back to the direct tag SHA.
commit="$(
    git ls-remote --tags "$FFMPEG_UPSTREAM_URL" "refs/tags/${latest_tag}^{}" \
        | awk 'NR == 1 { print $1 }'
)"

if [[ -z "$commit" ]]; then
    commit="$(
        git ls-remote --tags "$FFMPEG_UPSTREAM_URL" "refs/tags/${latest_tag}" \
            | awk 'NR == 1 { print $1 }'
    )"
fi

if [[ -z "$commit" ]]; then
    echo "Unable to resolve commit for $latest_tag" >&2
    exit 3
fi

emit_output found true
emit_output tag "$latest_tag"
emit_output version "$version"
emit_output commit "$commit"
