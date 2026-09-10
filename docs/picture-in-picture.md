# Processed HDR picture-in-picture

The public AVKit sample-buffer path accepts a completed neural RGBA16F frame and enters, exits and restores its source window on the tested Apple M3 with macOS 26.5. This establishes a viable float presentation route for further integration. It does not qualify streamed playback or physical HDR brightness. Roadmap #17 remains open and the app's PiP capability remains disabled.

Apple provides the sample-buffer content-source initializer and playback delegate on macOS 12 and later. This standalone probe requires macOS 26 because it uses the current asynchronous asset-reader API. It uses [AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller) with [AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer); no private PiP API or display capture is involved.

## Run the standalone probe

Build the shared engine using the repository's normal build first. The probe script compiles a separate app and records its binary, source, header, shared-library and metallib hashes. It does not rebuild shared playback binaries.

```sh
bash scripts/build-pip-probe.sh
artifacts/pip-probe/HDRPiPProbe.app/Contents/MacOS/HDRPiPProbe \
  --source assets/test-clips/hdr10-30.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --format float --report artifacts/pip-probe-float.json
```

Use `--format pq` for the explicit P010 conversion experiment. Omitting `--model` selects engine bypass and cannot demonstrate enhanced output. Run measurements sequentially without another GPU workload. The probe uses the first decoded image and supports even dimensions through 1080p; the validated fixture is unrotated, square-pixel PQ/BT.2020 with left-sited chroma.

The probe retains the exact completed engine lease through PiP. The source sample's output PTS, or sample PTS if needed, remains unchanged in the sample buffer and paused control timebase. Missing duration uses the next decoded image's exact PTS interval, with provenance in the report; it does not assume nominal frame rate. The interval is a held-frame display interval, not an assertion that an omitted container duration existed. It is never resubmitted to the temporal model for redraw, resize or restoration.

Public start/stop/restore and render-size delegates are recorded. The source window is resized during PiP; this does not count as resizing the system PiP window. Playback requests are recorded against a paused reference only. At teardown the display renderer flushes before the engine lease is released, the session is closed, idle is observed and the session is destroyed off the main thread. Application termination cannot bypass that drain.

## M3 result

The [compact evidence](evidence/m3-pip-held-frame.json) preserves exact source timing, conversion metrics, lifecycle events, hashes and the initial duration-validation failure. Both successful cases used one actual neural output (`contentKind=2`), source 320×192, processing 32×24, strength/colour strength 1, reference white 203 nits and maximum luminance ratio 2. Submitted/completed counts remained 1 throughout; exact PTS was 0/48000 and the next decoded interval was 512/15360. Both processes exited 0.

| Presentation surface | Public PiP lifecycle | Maximum / mean / RMS numeric error, nits | Interpretation |
| --- | --- | --- | --- |
| RGBA16F, linear BT.2020, values divided by 203 | Supported, possible, start, stop, restore; renderer rendering | 0.77344 / 0.05853 / 0.09226 | Float normalization round trip only; AVKit physical reference-white mapping is unverified |
| P010, PQ, limited range, BT.2020 NCL, 4:2:0 | Supported, possible, start, stop, restore; renderer rendering | 1112.93874 / 7.25421 / 25.62027 | Decode of the actual quantized/subsampled surface against the clipped input domain; includes chroma loss and 10-bit quantization |

Input RGB components ranged from 0.50684 to 2492 nits. Neither case contained negative or above-10000-nit components; PQ clipped zero components. PQ clamps those domains explicitly when present. Each experiment performs one full-frame CPU readback and one CPU surface write; framework-internal copies are unmeasured. These are probe costs, not the proposed production path.

Both cases produced a single 640×384 render-size delegate value. Actual PiP-window resizing, streamed controls, A/V synchronization, physical luminance/colour and external-display transitions were not measured. Renderer readiness and PiP entry alone cannot establish those properties. The 4:2:0 experiment's large chromatic-edge error disqualifies that conversion as the default path for preserving processed RGB; float transport avoids its subsampling and PQ-clipping loss.

A subsequent float rerun also passed after teardown hardening: renderer flush completed before engine destruction, idle was observed, occupied engine slots reached zero and close/drain took 35.8 microseconds. Its separate report and compiled-input hashes are retained in the same evidence file.

## Proposed integration boundary

The following work is proposed, not implemented. Keep libmpv as the sole decoder, audio output and playback-policy owner. AVKit receives the selected presentation frames; it does not create a second player or rerun enhancement.

1. **Export selected frames and clock state.** Add a versioned, explicitly optional extension in `vendor/mpv/include/mpv/hdr_frame.h`, implemented beside `player/client.c`. Export retained frame leases, source rational PTS/duration, source-to-player timeline offset, generation, content kind and a monotonically increasing presentation revision. Use `video/out/vo.c` at selection of a current frame and at `run_replace_current`, including same-PTS original/enhanced replacement. A completion in `vf_metal_hdr.m` is too early: it may be buffered, superseded or dropped before presentation. Publish through a bounded queue and a wakeup; never call AppKit while holding core/VO locks. Do not expose raw pointers through JSON properties.

2. **Reuse completed float surfaces.** `vf_metal_hdr.m` already creates GPU-complete IOSurface RGBA16F buffers in a six-buffer pool, normalizing absolute nits to libplacebo's 203-nit linear domain without clipping. `mp_image` retains those buffers. A PiP lease can retain that surface and a format description after completion, with linear BT.2020/extended-linear colour tags. No full-frame CPU readback or P010 conversion is necessary. Do not mutate attachment metadata while another renderer consumes the same surface; establish stable tags at publication or use independent format-description extensions. If AVKit requires a different proven unity mapping, add one bounded Metal normalization pass into a PiP pool and measure it.

3. **Keep retention bounded through actual AVFoundation ownership.** Add `apps/macos/Sources/PictureInPictureController.swift` and a small native bridge in `packages/CMpv`. Retain the CVPixelBuffer independently of the engine output lease; the existing normalization completion has already released the engine slot. Use renderer backpressure and an explicit cap on outstanding exported surfaces. An enqueue return is not a display/GPU completion signal. Pool allocation thresholds and retained CVPixelBuffer ownership must prevent recycling while AVFoundation holds a surface. Flush/cancel/drain on seek, generation change, renderer failure and exit, including queued old-generation samples. Measure contention with the existing six-buffer mpv pool before choosing whether PiP needs a separate capped pool.

4. **Bind the media timebase to the core clock.** Extend the native bridge with a snapshot from `player/video.c`/audio state: media time, corresponding monotonic host time, effective playback rate, seek generation, requested pause and actual enhancement-buffering hold. Preserve exact source timing separately from the normalized player timeline. The layer timebase must follow audio and Adaptive holds even when the host is obscured. The public display-layer contract supports a timebase sourced from a `CMAudioDeviceClock`; evaluate the current CoreAudio device clock where available, with explicit host/media anchors for seeks and offsets. A 100-ms JSON position poll or cached `avsync` is insufficient. Keep mpv audio active and invalidate/rebind clock state on device changes; do not start an independent audio renderer. Modern [receiver enqueue](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver/enqueue(_:)) provides backpressure when a render synchronizer is chosen; resolve that ownership against the existing mpv audio-clock path before implementation.

5. **Route controls through the existing native command worker.** In `MPVPlaybackController.swift`, map PiP `setPlaying` to the same pause-intent commands used by the app, and map skip requests to an exact seek. Complete a skip only once the new generation's timebase/preview is established, including failure completion. Report the real playable range and invalidate AVKit playback state after pause, duration, rate and buffering changes. Retained paused comparison must flush/re-enqueue the chosen same-PTS revision without model resubmission. `main.swift` owns only native window restoration and the availability binding; the web interface sends enter/exit intents. Neither source-host resizing nor PiP resizing should reload the model.

6. **Qualify activation and unsupported paths.** Keep public availability false until the current format, colour/units policy, clock bridge and retained-frame exporter pass their checks and AVKit reports possible. Report entry failures and return to the existing renderer with the correct generation/PTS. Initial integration can explicitly exclude Dolby Vision, because the float filter output does not include gpu-next's native DV reshaping. A pre-composition frame export also omits mpv subtitles/OSD; either expose that limitation before entry or add a separately measured float composition pass in `vo_gpu_next.c`. Do not call raw DV/P010 transport an enhanced float path. Verify foreground/background/minimized source-window operation, restoration, real PiP resize, repeated entry/exit, paused seeks/compare, Adaptive holds, Prepared cache transitions and audio-device changes before enabling #17 in the app.

The next bounded prototype should stream the existing completed RGBA16F surfaces with a core-clock snapshot, first using the current SDR/PQ/HLG fixtures and no subtitles/DV. Acceptance requires measured source-PTS/generation correctness, bounded retained surfaces, unchanged temporal submission counts for paused redraw, controls/return behavior and sustained A/V offset within the existing playback target. Numeric float preservation and physical HDR/reference-white validation are separate gates; this held-frame result satisfies neither streamed gate by itself.
