# Implementation boundaries

These boundaries hold on `main` today. [Implementation status](implementation-status.md) lists the open work, and the [original plan](../mac-hdr-player-plan.md) is the architecture reference.

## Decided

- **Playback core is mpv.** [#11](https://github.com/ScriptType/metal-dlss-mac-video/issues/11) selected it from the [matched M3 comparison](adapter-comparison.md). The Erika adapter is frozen. Reopen the decision only if the M5 run in [#8](https://github.com/ScriptType/metal-dlss-mac-video/issues/8) shows an mpv-specific bottleneck.
- **System picture-in-picture is dropped.** Apple DTS states that sample-buffer PiP is supported only on iOS ([forum thread](https://developer.apple.com/forums/thread/830764)). [#38](https://github.com/ScriptType/metal-dlss-mac-video/issues/38) removes the disabled code path. The app-owned floating video window in [#17](https://github.com/ScriptType/metal-dlss-mac-video/issues/17) replaces it.
- **Direct Metal libplacebo and a custom playback core are not planned** ([#19](https://github.com/ScriptType/metal-dlss-mac-video/issues/19), [#20](https://github.com/ScriptType/metal-dlss-mac-video/issues/20)).

## Pipeline ownership

- `vendor/MLX-DLSS` owns decoding into retained planes (`NativeHDRVideoReader.nextDecoded()`), import to linear BT.2020 nits (`MLXHDRImporter`) and neural proxy inference with HDR reconstruction (`NativeHDRProcessor`).
- `packages/FrameEngine` owns bounded scheduling and output leases (`FrameSession`), the bridge to the fork (`HDRPipelineProcessor`) and the Prepared cache (`HDRSegmentCache`, `HDRPreparationCoordinator`). [Frame engine](frame-engine.md) and [cache policy](hdr-cache.md) describe the contracts.
- `packages/CFrameEngine/include/frame_engine.h` is the C boundary that mpv calls.
- The app embeds mpv and routes video, audio, tracks, subtitles and playback commands through its native worker ([native player](native-player.md)).

## Repository rules

- Changes to `vendor/MLX-DLSS`, `vendor/mpv` or `vendor/Erika` land on the fork's `hdr-player` branch before the root pin moves.
- Generated media, model weights, run logs and build products stay out of Git. They go in `artifacts/` or `models/`, which Git ignores. `scripts/audit-public-tree.py` rejects tracked model, media and build files and any `docs/evidence` file over 256 KB.
- Close an issue only on the evidence its "Done when" list asks for, not on a successful build.
