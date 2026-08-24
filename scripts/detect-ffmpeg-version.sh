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
: "${FFMPEG_MIN_VERSION:?FFMPEG_MIN_VERSION is required}"

if ! [[ "$FFMPEG_MIN_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "FFMPEG_MIN_VERSION must match X.Y or X.Y.Z" >&2
    exit 2
fi

version_ge() {
    local lhs="$1"
    local rhs="$2"
    local l_major l_minor l_patch r_major r_minor r_patch

    IFS='.' read -r l_major l_minor l_patch <<< "$lhs"
    IFS='.' read -r r_major r_minor r_patch <<< "$rhs"
    l_patch="${l_patch:-0}"
    r_patch="${r_patch:-0}"

    if (( l_major > r_major )); then return 0; fi
    if (( l_major < r_major )); then return 1; fi
    if (( l_minor > r_minor )); then return 0; fi
    if (( l_minor < r_minor )); then return 1; fi
    if (( l_patch >= r_patch )); then return 0; fi
    return 1
}

emit_output() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

mapfile -t candidate_tags < <(
    git ls-remote --tags --refs "$FFMPEG_UPSTREAM_URL" 'refs/tags/n*' \
        | awk '{print $2}' \
        | sed 's#^refs/tags/##' \
        | grep -E '^n[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | sort -Vu
)

eligible_tags=()
for tag in "${candidate_tags[@]}"; do
    version="${tag#n}"
    if version_ge "$version" "$FFMPEG_MIN_VERSION"; then
        eligible_tags+=("$tag")
    fi
done

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
