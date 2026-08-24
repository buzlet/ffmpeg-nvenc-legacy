# ffmpeg-nvenc-legacy

Reproducible FFmpeg builds for NVIDIA systems that must stay on legacy driver branches.

## Version policy

Only official FFmpeg version tags matching:

```text
nX.Y
nX.Y.Z
```

are eligible, and only when `X > 9`.

Examples accepted: `n10.0`, `n10.0.1`, `n11.2`.

Examples ignored: `n9.0.1`, snapshots, nightly/date builds, release candidates, development commits, and descriptive tags.

The current NVIDIA compatibility baseline is pinned independently from FFmpeg:

```text
nv-codec-headers: n13.0.19.1
NVENC API:        13.0
```

## Targets

Current active target:

- Windows x86_64 (`win64`), static GPL build

Linux x86_64 is intentionally reserved for a later phase and is not part of the active build matrix yet.

## CI stages

The project is being introduced in stages:

1. Detect the newest eligible upstream FFmpeg version.
2. Build reproducibly with the pinned legacy NVENC API.
3. Validate the produced binaries.
4. Publish immutable GitHub Release assets.
5. Update the `ffmpeg-nvenc-legacy` manifest in the Scoop bucket.

At the current stage CI performs detection only. It does not compile or publish releases.
