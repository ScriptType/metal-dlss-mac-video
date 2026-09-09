# Next implementation steps

1. Extend `vendor/MLX-DLSS/Sources/DLSSMedia/NativeVideoReader.swift` and `DLSSMLX/MLXVideoFrame.swift` from the plan's pinned baseline. Import NV12/P010 planes, retain CoreVideo owners and source metadata, and establish linear BT.2020 with documented luminance units. Use the prepared probe and raw-nit fixture to check the boundary.
2. Add a native RGBA16F/EDR presentation harness for those frames. The current AVPlayerView is a bypass baseline and does not expose the future neural presentation path.
3. Wire proxy, inference and HDR reconstruction through the existing display codecs. Verify zero-strength identity against the retained original, including wide-gamut patches and highlight values.
4. Implement the asynchronous frame engine and its C ABI only once real buffer ownership and synchronization are established. Preserve rational PTS, generations and temporal history; start with three slots. `packages/FrameEngine` currently contains diagnostics, not that scheduler.
5. Build thin mpv/Erika adapters around the same engine, then compare. The sources and native builds are ready; neither has a neural-frame integration yet. Keep mpv as the initial candidate per the plan.

The MLX fork has `origin=ScriptType/MLX-DLSS`, `upstream=iamwavecut/MLX-DLSS`, and local/remote branch `hdr-player`. Commit engine changes there first, push that branch, then update the root submodule pointer. Fork mpv or Erika when an actual integration patch is ready. libplacebo's direct Metal backend remains conditional on measured need, as specified by the plan.

The initial fixture corpus does not cover VFR, long-form A/V drift, complex subtitles, Dolby Vision profiles, display migration, or production neural quality. Add those assets and checks as the corresponding paths become testable; the acceptance matrix in the original plan remains authoritative.
