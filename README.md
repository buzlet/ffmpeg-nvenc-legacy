# ffmpeg-nvenc-legacy

Reproducible Windows FFmpeg builds for NVIDIA systems that must remain on legacy driver branches.

The project tracks official FFmpeg releases while deliberately pinning the NVIDIA codec headers to NVENC API 13.0.

## Compatibility baseline

```text
nv-codec-headers: n13.0.19.1
NVENC API:        13.0
```

The headers are installed explicitly during every build. The version bundled in the upstream build container is removed first and is never trusted implicitly.

## FFmpeg version policy

Only official FFmpeg tags matching exactly:

```text
nX.Y
nX.Y.Z
```

are eligible, starting with `n8.1.2` inclusive.

Examples accepted:

```text
n8.1.2
n9.0
n9.0.1
n10.0
n10.0.1
```

Ignored intentionally:

- versions older than `n8.1.2`
- release candidates
- snapshots and nightly/date builds
- development commits and descriptive tags

Every eligible official version is considered independently. For example, `n9.0` and `n9.0.1` are separate releases; the existence of the latter does not hide the former.

## Windows build

Current active target:

```text
Windows x86_64
GPL static
ffmpeg.exe
ffprobe.exe
ffplay.exe
```

The build uses BtbN's MinGW/Docker dependency environment, but checks out the exact FFmpeg version tag and replaces its bundled `ffnvcodec` headers with the exact project pin before configuring FFmpeg.

Each ZIP also contains:

```text
BUILD-INFO.txt
BINARY-SHA256SUMS.txt
DLL-DEPENDENCIES.txt
LICENSE.txt
```

`BUILD-INFO.txt` records the exact FFmpeg commit, nv-codec-headers commit, build-container reference, image digest and image ID.

Linux x86_64 is reserved for a later phase and is not part of the active build matrix yet.

## Release naming

Project releases are immutable and versioned independently from FFmpeg build revisions:

```text
v<ffmpeg-version>-nv13.0-r<revision>
```

Example:

```text
v9.0.1-nv13.0-r1
```

Runtime asset:

```text
ffmpeg-9.0.1-win64-gpl-nvenc13.0.zip
```

A SHA-256 sidecar is published next to every ZIP.

## Automation

`release-win64.yml` runs on schedule and can also be invoked manually. It:

1. Enumerates all strict official FFmpeg version tags from `8.1.2` onward.
2. Compares them with existing `ffmpeg-nvenc-legacy` releases.
3. Skips versions already published for the current project revision.
4. Builds every missing version with `nv-codec-headers n13.0.19.1`.
5. Validates that NVENC encoders are present and verifies the generated archive checksum.
6. Publishes the ZIP and SHA-256 file as a GitHub Release.

The separate `build-win64.yml` workflow is a manual diagnostic baseline build for FFmpeg 8.1.2 and records hosted-runner resource usage.

## Scoop

The companion `scoop-be` bucket contains the `ffmpeg-nvenc-legacy` manifest. Its updater selects the highest semantic project release, not merely the most recently published release, so rebuilding an older FFmpeg version cannot accidentally downgrade the package.

Installation:

```powershell
scoop bucket add scoop-be https://github.com/buzlet/scoop-be
scoop install ffmpeg-nvenc-legacy
```

The package exposes `ffmpeg`, `ffprobe` and `ffplay` shims. Installing it alongside another FFmpeg package can therefore create competing shims; normally only one FFmpeg package should provide those command names.

## Validation scope

CI validates the exact source/header versions, successful cross-compilation, presence of `h264_nvenc` and `hevc_nvenc`, packaging, and SHA-256 integrity. Actual NVENC/NVDEC execution still depends on the target NVIDIA GPU and driver and should be hardware-tested separately.
