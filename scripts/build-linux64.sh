#!/usr/bin/env bash
# scripts/build-linux64.sh
set -euo pipefail

VERSION="${1:?FFmpeg version is required, e.g. 8.1.2}"
BTBN_SERIES="${2:-auto}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.1}"
BTBN_BUILD_COMMIT="${BTBN_BUILD_COMMIT:-a1b5c414d3c53f5abf5baf73df9607cdf77bb46a}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$PWD/.work-linux64-${VERSION}}"

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
    CANDIDATE_IMAGE="ghcr.io/btbn/ffmpeg-builds/linux64-gpl-${BTBN_SERIES}:latest"
    FALLBACK_IMAGE="ghcr.io/btbn/ffmpeg-builds/linux64-gpl:latest"
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

# The builder image needs root for its baked-in FFBUILD_PREFIX. Any files
# created on the bind mount are returned to the GitHub runner on every exit.
restore_host_ownership() {
    chown -R "$HOST_UID:$HOST_GID" /work 2>/dev/null || true
}
trap restore_host_ownership EXIT

cd /work
rm -rf ffmpeg nv-codec-headers prefix package out
mkdir -p prefix package out

# Never use whichever ffnvcodec happens to be baked into the current image.
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

# Use BtbN's Linux dependency/toolchain environment, but exact upstream
# sources and exact nv-codec-headers are controlled by this project.
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

# Build-time feature validation. Actual NVIDIA execution remains a hardware
# test on a machine with a compatible GPU and driver.
grep -a -q 'h264_nvenc' /work/prefix/bin/ffmpeg
grep -a -q 'hevc_nvenc' /work/prefix/bin/ffmpeg

for exe in ffmpeg ffprobe ffplay; do
    test -x "/work/prefix/bin/$exe"
    readelf -h "/work/prefix/bin/$exe" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "/work/prefix/bin/$exe" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
done

PKG="/work/package/ffmpeg-${FFMPEG_VERSION}-linux64-gpl-nvenc13.0"
mkdir -p "$PKG"
cp /work/prefix/bin/ffmpeg "$PKG/"
cp /work/prefix/bin/ffprobe "$PKG/"
cp /work/prefix/bin/ffplay "$PKG/"
cp COPYING.GPLv3 "$PKG/LICENSE.txt"

{
    echo "Product: ffmpeg-nvenc-legacy"
    echo "Target: Linux x86_64"
    echo "Variant: GPL static dependencies"
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
    sha256sum ffmpeg ffprobe ffplay > BINARY-SHA256SUMS.txt
)

{
    for exe in ffmpeg ffprobe ffplay; do
        echo "== $exe =="
        readelf -h "$PKG/$exe"
        echo
        echo '-- dynamic dependencies --'
        ldd "$PKG/$exe" 2>&1 || true
        echo
    done
} > "$PKG/ELF-INFO.txt"

ARCHIVE="ffmpeg-${FFMPEG_VERSION}-linux64-gpl-nvenc13.0.tar.xz"
tar -C "$PKG" -cJf "/work/out/$ARCHIVE" \
    ffmpeg ffprobe ffplay \
    BUILD-INFO.txt BINARY-SHA256SUMS.txt ELF-INFO.txt LICENSE.txt

tar -tJf "/work/out/$ARCHIVE" >/dev/null
(
    cd /work/out
    sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
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
ls -lh "$OUT_DIR"/ffmpeg-"$VERSION"-linux64-gpl-nvenc13.0.tar.xz*