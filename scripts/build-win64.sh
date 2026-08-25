#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?FFmpeg version is required, e.g. 8.1.2}"
BTBN_SERIES="${2:-auto}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.1}"
BTBN_BUILD_COMMIT="${BTBN_BUILD_COMMIT:-a1b5c414d3c53f5abf5baf73df9607cdf77bb46a}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$PWD/.work-${VERSION}}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid FFmpeg version: $VERSION" >&2
    exit 2
fi

if [[ "$BTBN_SERIES" == auto ]]; then
    IFS='.' read -r major minor _ <<< "$VERSION"
    BTBN_SERIES="${major}.${minor}"
fi

if [[ -n "${BTBN_IMAGE:-}" ]]; then
    IMAGE="$BTBN_IMAGE"
    printf 'Pulling explicitly selected image %s\n' "$IMAGE"
    docker pull "$IMAGE"
else
    CANDIDATE_IMAGE="ghcr.io/btbn/ffmpeg-builds/win64-gpl-${BTBN_SERIES}:latest"
    FALLBACK_IMAGE="ghcr.io/btbn/ffmpeg-builds/win64-gpl:latest"
    printf 'Trying BtbN branch image %s\n' "$CANDIDATE_IMAGE"
    if docker pull "$CANDIDATE_IMAGE"; then
        IMAGE="$CANDIDATE_IMAGE"
    else
        echo "Branch image is unavailable; falling back to $FALLBACK_IMAGE" >&2
        docker pull "$FALLBACK_IMAGE"
        IMAGE="$FALLBACK_IMAGE"
    fi
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

IMAGE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}')"
IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
printf 'Image digest: %s\n' "$IMAGE_DIGEST"
printf 'Image id: %s\n' "$IMAGE_ID"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cat > "$WORK_DIR/container-build.sh" <<'CONTAINER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

: "${FFMPEG_VERSION:?}"
: "${NV_CODEC_HEADERS_TAG:?}"
: "${BTBN_IMAGE_REF:?}"
: "${BTBN_IMAGE_DIGEST:?}"
: "${BTBN_IMAGE_ID:?}"
: "${BTBN_BUILD_COMMIT:?}"
: "${HOST_UID:?}"
: "${HOST_GID:?}"
: "${FFBUILD_PREFIX:?BtbN image does not define FFBUILD_PREFIX}"

# The BtbN image runs as root because its baked-in FFBUILD_PREFIX is root-owned.
# Always return ownership of bind-mounted files to the GitHub runner, even if
# configure/make/package fails halfway through.
restore_host_ownership() {
    chown -R "$HOST_UID:$HOST_GID" /work 2>/dev/null || true
}
trap restore_host_ownership EXIT

cd /work
rm -rf ffmpeg nv-codec-headers prefix package out
mkdir -p prefix package out

# Never trust the ffnvcodec version baked into the upstream image. Replace it
# explicitly with the exact legacy API baseline selected by this project.
rm -rf "${FFBUILD_PREFIX}/include/ffnvcodec"
rm -f "${FFBUILD_PREFIX}/lib/pkgconfig/ffnvcodec.pc"

git clone --filter=blob:none --depth 1 --branch "$NV_CODEC_HEADERS_TAG" \
    https://github.com/FFmpeg/nv-codec-headers.git nv-codec-headers
NV_HEADERS_COMMIT="$(git -C nv-codec-headers rev-parse HEAD)"
make -C nv-codec-headers PREFIX="$FFBUILD_PREFIX" install

export PKG_CONFIG_PATH="${FFBUILD_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
FFNVCODEC_VERSION="$(pkg-config --modversion ffnvcodec)"
printf 'Pinned ffnvcodec version: %s\n' "$FFNVCODEC_VERSION"
[[ "$FFNVCODEC_VERSION" == 13.0.19.1.2 ]]
grep -Eq '^#define[[:space:]]+NVENCAPI_MAJOR_VERSION[[:space:]]+13' \
    "$FFBUILD_PREFIX/include/ffnvcodec/nvEncodeAPI.h"
grep -Eq '^#define[[:space:]]+NVENCAPI_MINOR_VERSION[[:space:]]+0' \
    "$FFBUILD_PREFIX/include/ffnvcodec/nvEncodeAPI.h"

git clone --filter=blob:none --depth 1 --branch "n${FFMPEG_VERSION}" \
    https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg
FFMPEG_COMMIT="$(git rev-parse HEAD)"
FFMPEG_TAG="$(git describe --tags --exact-match HEAD)"
[[ "$FFMPEG_TAG" == "n${FFMPEG_VERSION}" ]]

# Match BtbN's build environment, but pin the exact FFmpeg tag and remove
# their date-based --extra-version. The image supplies dependency flags.
# shellcheck disable=SC2086
./configure \
    --prefix=/work/prefix \
    --pkg-config-flags="--static" \
    ${FFBUILD_TARGET_FLAGS:-} ${FF_CONFIGURE:-} \
    --extra-cflags="${FF_CFLAGS:-}" \
    --extra-cxxflags="${FF_CXXFLAGS:-}" \
    --extra-libs="${FF_LIBS:-}" \
    --extra-ldflags="${FF_LDFLAGS:-}" \
    --extra-ldexeflags="${FF_LDEXEFLAGS:-}" \
    --cc="${CC:?}" --cxx="${CXX:?}" --ar="${AR:?}" \
    --ranlib="${RANLIB:?}" --nm="${NM:?}" \
    --extra-version="nvenc-legacy-nv13.0" \
    || { cat ffbuild/config.log; exit 1; }

make -j"$(nproc)"
make install

# Compile-time validation. Hardware execution on a Pascal GPU is a separate
# test, but these checks catch accidental loss of NVENC at build time.
grep -Rqs '^#define CONFIG_H264_NVENC_ENCODER 1' ffbuild config_components.h config.h || \
    grep -a -q 'h264_nvenc' /work/prefix/bin/ffmpeg.exe
grep -Rqs '^#define CONFIG_HEVC_NVENC_ENCODER 1' ffbuild config_components.h config.h || \
    grep -a -q 'hevc_nvenc' /work/prefix/bin/ffmpeg.exe
grep -a -q 'h264_nvenc' /work/prefix/bin/ffmpeg.exe
grep -a -q 'hevc_nvenc' /work/prefix/bin/ffmpeg.exe

PKG="/work/package/ffmpeg-${FFMPEG_VERSION}-win64-gpl-nvenc13.0"
mkdir -p "$PKG"
cp /work/prefix/bin/ffmpeg.exe "$PKG/"
cp /work/prefix/bin/ffprobe.exe "$PKG/"
cp /work/prefix/bin/ffplay.exe "$PKG/"
cp COPYING.GPLv3 "$PKG/LICENSE.txt"

{
    echo "Product: ffmpeg-nvenc-legacy"
    echo "Target: Windows x86_64"
    echo "Variant: GPL static"
    echo "FFmpeg tag: n${FFMPEG_VERSION}"
    echo "FFmpeg commit: ${FFMPEG_COMMIT}"
    echo "nv-codec-headers tag: ${NV_CODEC_HEADERS_TAG}"
    echo "nv-codec-headers commit: ${NV_HEADERS_COMMIT}"
    echo "ffnvcodec pkg-config version: ${FFNVCODEC_VERSION}"
    echo "NVENC API: 13.0"
    echo "BtbN build-system reference commit: ${BTBN_BUILD_COMMIT}"
    echo "BtbN image: ${BTBN_IMAGE_REF}"
    echo "BtbN image digest: ${BTBN_IMAGE_DIGEST}"
    echo "BtbN image id: ${BTBN_IMAGE_ID}"
    echo "Build date UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PKG/BUILD-INFO.txt"

(
    cd "$PKG"
    sha256sum ffmpeg.exe ffprobe.exe ffplay.exe > BINARY-SHA256SUMS.txt
)

{
    for exe in ffmpeg.exe ffprobe.exe ffplay.exe; do
        echo "== $exe =="
        "${OBJDUMP:-${CROSS_PREFIX:-x86_64-w64-mingw32-}objdump}" -p "$PKG/$exe" \
            | awk '/DLL Name:/ { print }'
    done
} > "$PKG/DLL-DEPENDENCIES.txt" || true

ZIP_NAME="ffmpeg-${FFMPEG_VERSION}-win64-gpl-nvenc13.0.zip"
(
    cd "$PKG"
    zip -9 -q "/work/out/${ZIP_NAME}" \
        ffmpeg.exe ffprobe.exe ffplay.exe \
        BUILD-INFO.txt BINARY-SHA256SUMS.txt DLL-DEPENDENCIES.txt LICENSE.txt
)
(
    cd /work/out
    sha256sum "$ZIP_NAME" > "${ZIP_NAME}.sha256"
)
CONTAINER_SCRIPT
chmod +x "$WORK_DIR/container-build.sh"

docker run --rm -i \
    -e FFMPEG_VERSION="$VERSION" \
    -e NV_CODEC_HEADERS_TAG="$NV_CODEC_HEADERS_TAG" \
    -e BTBN_IMAGE_REF="$IMAGE" \
    -e BTBN_IMAGE_DIGEST="$IMAGE_DIGEST" \
    -e BTBN_IMAGE_ID="$IMAGE_ID" \
    -e BTBN_BUILD_COMMIT="$BTBN_BUILD_COMMIT" \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -v "$WORK_DIR:/work" \
    "$IMAGE" bash /work/container-build.sh

cp "$WORK_DIR"/out/* "$OUT_DIR"/

printf 'Built artifacts:\n'
ls -lh "$OUT_DIR"/ffmpeg-"$VERSION"-win64-gpl-nvenc13.0.zip*
