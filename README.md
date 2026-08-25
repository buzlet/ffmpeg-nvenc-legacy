# ffmpeg-nvenc-legacy

[![Win64 release](https://github.com/buzlet/ffmpeg-nvenc-legacy/actions/workflows/release-win64.yml/badge.svg?branch=main)](https://github.com/buzlet/ffmpeg-nvenc-legacy/actions/workflows/release-win64.yml)
[![Linux64 release](https://github.com/buzlet/ffmpeg-nvenc-legacy/actions/workflows/release-linux64.yml/badge.svg?branch=main)](https://github.com/buzlet/ffmpeg-nvenc-legacy/actions/workflows/release-linux64.yml)
[![Latest built version](https://img.shields.io/github/v/release/buzlet/ffmpeg-nvenc-legacy?display_name=tag&sort=semver&label=latest%20built)](https://github.com/buzlet/ffmpeg-nvenc-legacy/releases/latest)
[![NVENC API](https://img.shields.io/badge/NVENC%20API-13.0-76B900)](https://github.com/FFmpeg/nv-codec-headers/tree/n13.0.19.1)
[![Builder](https://img.shields.io/badge/builder-GitHub--hosted%20Ubuntu%2024.04-2088FF)](https://github.com/buzlet/ffmpeg-nvenc-legacy/actions)
[![Targets](https://img.shields.io/badge/targets-Win64%20%7C%20Linux64-informational)](https://github.com/buzlet/ffmpeg-nvenc-legacy/releases)
[![Download](https://img.shields.io/badge/download-latest%20release-success)](https://github.com/buzlet/ffmpeg-nvenc-legacy/releases/latest)
[![Scoop](https://img.shields.io/badge/Scoop-scoop--be-blue)](https://github.com/buzlet/scoop-be/blob/main/bucket/ffmpeg-nvenc-legacy.json)

Current FFmpeg releases rebuilt for NVIDIA systems that must remain on legacy driver branches. Official FFmpeg version tags are compiled with **nv-codec-headers `n13.0.19.1` / NVENC API 13.0** instead of whatever NVIDIA headers happen to be present in the upstream builder image.

The status badges above are live: they show whether the latest Windows/Linux workflow completed successfully and which project release is currently the newest.

## Build model

Builds run on **GitHub-hosted `ubuntu-24.04` runners**. The temporary `u24` development machine is not part of the production pipeline.

The project uses BtbN FFmpeg-Builds Docker environments for the compiler and prebuilt dependencies, but controls the parts relevant to reproducibility and legacy NVIDIA compatibility itself:

1. Reclaim space on the disposable GitHub runner by removing unused Android/.NET/GHC/Boost/toolcache payloads.
2. Pull the BtbN image matching the FFmpeg release series, with the generic target image as a fallback.
3. Remove the `ffnvcodec` headers bundled in that image.
4. Install exactly `nv-codec-headers n13.0.19.1` and verify pkg-config version `13.0.19.1.2` plus NVENC API `13.0`.
5. Clone the exact official FFmpeg tag being built.
6. Configure and compile using the BtbN dependency/toolchain environment.
7. Verify that `h264_nvenc` and `hevc_nvenc` are present.
8. Package binaries, build metadata and checksums.
9. Record the actual BtbN image digest and image ID in `BUILD-INFO.txt`.

The BtbN image currently enters by its series `:latest` tag; the exact pulled digest is recorded in every produced artifact. Pinning the image by digest is a possible later hardening step once the build environment is intentionally frozen.

Docker runs as root because the BtbN image owns its internal build prefix as root. A container EXIT trap recursively returns ownership of bind-mounted working files to the GitHub runner, including failed builds, preventing cleanup failures caused by mixed root/runner ownership.

## FFmpeg version policy

Only official FFmpeg tags matching exactly:

```text
nX.Y
nX.Y.Z
```

are eligible, starting with **`n8.1.2` inclusive**.

Accepted examples include `n8.1.2`, `n9.0`, `n9.0.1`, `n10.0` and `n10.0.1`.

Versions older than `n8.1.2`, release candidates, snapshots, nightly/date builds, development commits and descriptive tags are intentionally ignored.

Every official version is independent. `n9.0` and `n9.0.1`, for example, are separate build targets.

## Windows x86_64

Windows builds are GPL static-dependency builds containing:

```text
ffmpeg.exe
ffprobe.exe
ffplay.exe
BUILD-INFO.txt
BINARY-SHA256SUMS.txt
DLL-DEPENDENCIES.txt
LICENSE.txt
```

`release-win64.yml` deliberately processes **exactly one FFmpeg version per workflow run**:

1. Enumerate eligible official tags in ascending version order.
2. Find the first version whose `v<version>-nv13.0-r1` release does not exist.
3. Build only that version.
4. Verify its archive checksum.
5. Publish its ZIP and SHA-256 sidecar as a GitHub Release.
6. Stop.

The next scheduled or manual run advances to the next missing version. Existing releases are never rebuilt merely because a later version exists.

`build-win64.yml` remains a manual diagnostic baseline workflow for FFmpeg 8.1.2 and records GitHub-hosted runner resource usage.

## Linux x86_64

Linux uses a completely separate build script and workflow so a Linux failure cannot break the Windows release path.

`release-linux64.yml` also processes **exactly one FFmpeg version per run**. It scans existing Windows-created project releases from oldest to newest, finds the first one that does not yet contain its Linux asset, builds that version, and uploads the Linux archive plus SHA-256 sidecar into the same versioned GitHub Release.

Linux archive naming:

```text
ffmpeg-<version>-linux64-gpl-nvenc13.0.tar.xz
```

The package contains `ffmpeg`, `ffprobe`, `ffplay`, `BUILD-INFO.txt`, binary checksums, ELF/dependency information and the GPL license. The BtbN linux64 target is intended for x86_64 Linux with glibc 2.28+ and Linux kernel 4.18+.

## Release naming

Project release tag:

```text
v<ffmpeg-version>-nv13.0-r<revision>
```

Example:

```text
v9.0.1-nv13.0-r1
```

Windows asset:

```text
ffmpeg-9.0.1-win64-gpl-nvenc13.0.zip
```

Linux asset:

```text
ffmpeg-9.0.1-linux64-gpl-nvenc13.0.tar.xz
```

A SHA-256 sidecar is published next to each binary archive.

## Scoop

The companion [`scoop-be`](https://github.com/buzlet/scoop-be) bucket contains `ffmpeg-nvenc-legacy`. Its updater selects the highest semantic project release, obtains the immutable release asset URL and SHA-256, validates the generated JSON and commits only when the manifest actually changed.

Installation:

```powershell
scoop bucket add scoop-be https://github.com/buzlet/scoop-be
scoop install ffmpeg-nvenc-legacy
```

The package exposes `ffmpeg`, `ffprobe` and `ffplay` shims. Installing it alongside another FFmpeg Scoop package can therefore create competing shims; normally only one package should own those command names.

## Validation scope

CI validates exact source/header versions, successful compilation, presence of `h264_nvenc` and `hevc_nvenc`, executable architecture, packaging and SHA-256 integrity. Runtime NVENC/NVDEC/CUDA behavior still depends on the target NVIDIA GPU and driver and is hardware-tested separately.
