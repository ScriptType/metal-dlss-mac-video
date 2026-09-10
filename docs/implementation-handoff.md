# Implementation boundaries

The [roadmap status](implementation-status.md) tracks remaining requirements against the unchanged [implementation plan](../mac-hdr-player-plan.md).

## Shared pipeline

`vendor/MLX-DLSS` provides `NativeHDRVideoReader.nextDecoded()` for retained decoder planes and metadata, `MLXHDRImporter` for completed linear BT.2020 originals in nits, and persistent `NativeHDRProcessor` for bounded sRGB proxy inference plus original-based HDR reconstruction. Its `hdr-player` branch owns these changes. `NativeHDRVideoReader.next()` combines decode/import for diagnostic callers. SDR media export has a separate explicit output policy.

The root `FrameSession` implements bounded admission, serial temporal execution, generation cancellation and completed-output leases. `HDRPipelineProcessor` connects the fork to its C ABI. Player adapters share `packages/CFrameEngine/include/frame_engine.h`; [ownership and measurements](frame-engine.md) apply equally to both candidates.

`HDRMetalView` presents completed floating-point nits through the separate video-only HDRHarness's native extended-linear P3 EDR layer. Its [display policy and diagnostic commands](hdr-presentation.md) define the bypass boundary and capture interpretation. The integrated [native player](native-player.md) embeds mpv and routes video, audio, tracks, subtitle composition and playback commands through its native worker.

`HDRSegmentCache` publishes only validated complete float HDR ranges. `HDRPreparationCoordinator` cancels/coalesces jobs, resets temporal history at deterministic preroll and reuses completed segments. [Prepared playback](prepared-playback.md) integrates those segments under mpv's clock, preserves exact source identity and falls back to Original on misses. The sustained M3 case passes source-cadence, boundary-seek, reuse and resource checks; larger workloads and physical display/audio accuracy retain separate gates. See the [cache policy](hdr-cache.md).

The [diagnostic PiP consumer](picture-in-picture.md) uses the optional `vendor/mpv/include/mpv/hdr_frame.h` selected-frame/clock interface. It shares the existing decoder, audio and completed float surfaces, including valid Original cache misses. Bounded leases and tested lifecycle behavior do not establish AVFoundation's internal retention, physical HDR or presented A/V continuity; ordinary PiP remains disabled pending those checks.

## Candidate integration and selection

Keep mpv as the provisional core. Both adapter prototypes must preserve the shared ownership/timing boundaries, native HDR output and comparable completed-work instrumentation. Compare identical source/model/settings/display dimensions with sequential, alternating runs. M3 evidence supports development; final core selection and sustainable configurations require M5 Max results.

Land MLX-DLSS, mpv and Erika changes on their published forks' `hdr-player` branches before updating root pointers. Keep generated media, weights, private traces and build products outside tracked source. Do not close candidate evaluations or the parent roadmap from compilation alone.

Direct Metal libplacebo and custom FFmpeg/VideoToolbox core work retain their measured activation gates. PiP and Dolby Vision require separate processed-output/profile qualification. The original plan's acceptance corpus includes VFR, 24/30/60 fps, long-GOP seeking, sustained A/V drift, temporal scenes, styled subtitles, multiple tracks and display/lifecycle transitions.
