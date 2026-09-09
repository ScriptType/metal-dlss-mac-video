# Erika shared HDR adapter

The optional `shared-hdr` feature inserts the shared frame engine between Erika's VideoToolbox decoder and its native Metal renderer. It is a comparison prototype; playback-core selection and synchronized Live/Adaptive buffering remain separate milestones.

## Build and run

The build script prepares `FrameEngineShared`, its MLX runtime and the adapter against the same C header:

```sh
bash scripts/build-erika-adapter.sh

# Retained-original HDR bypass.
bash scripts/run-erika-adapter.sh assets/test-clips/hdr10-30.mp4

# Neural processing at independently configured dimensions.
ERIKA_FRAME_ENGINE_REPORT="$PWD/artifacts/erika-adapter/pq-enhanced.json" \
ERIKA_FRAME_ENGINE_CAPTURE="$PWD/artifacts/erika-adapter/pq-enhanced" \
bash scripts/run-erika-adapter.sh assets/test-clips/hdr10-30.mp4 \
  "$PWD/models/neural-rendering/NeuralRendering.dlssmodel"

# Zero-strength and a reproducible seek through the normal presenter.
ERIKA_FRAME_ENGINE_STRENGTH=0 ERIKA_ADAPTER_SEEK_AT=1 \
ERIKA_ADAPTER_SEEK_TO=0.25 ERIKA_ADAPTER_SECONDS=8 \
bash scripts/run-erika-adapter.sh assets/test-clips/hdr10-30.mp4 \
  "$PWD/models/neural-rendering/NeuralRendering.dlssmodel"
```

Repeat with `hlg-60.mp4` and `sdr-24.mp4`. Defaults are processing 32×24, reference white 203 nits, colour strength 1 and maximum luminance ratio 2. Source and display dimensions are independent. The native example reports the actual physical drawable extent; `ERIKA_FRAME_ENGINE_WIDTH` and `ERIKA_FRAME_ENGINE_HEIGHT` change only processing dimensions.

`ERIKA_FRAME_ENGINE` names the dynamic library. Without it, the optional feature leaves Erika's ordinary renderer active. `ERIKA_FRAME_ENGINE_MODEL` selects the extracted model directory; absence selects bypass. The script records the model manifest's weights hash and exact source rate/dimensions. Reports are local ignored artifacts, with a separate `.adapter.json` containing admission drops and native-renderer statistics.

## Ownership and timing

`SharedHDRRenderer.upload_player_frame` submits immutable VideoToolbox planes through the C ABI and returns immediately. The C bridge compiles against `frame_engine.h`, so it does not duplicate the Swift ABI layout in Rust. It carries source rational PTS/duration, crop, pixel aspect, frame display rotation, colour interpretation and available mastering/content-light metadata. The engine retains the CoreVideo buffer on acceptance before Erika can release the decoded `AVFrame`.

Before each native presentation, the wrapper polls completed outputs. A completed RGBA16F buffer is imported directly with `CVMetalTextureCache`. Engine output leases are shared with the native frame and captured by Metal command-completion handlers; the resource cannot be recycled while a command still reads it. `CAMetalDrawable` presentation callbacks retain the session and record the actual presentation host timestamp. Repeated draws reuse the completed output without submitting neural history again.

Presenter generations invalidate pending/completed output on seeks, source changes and transitions. The wrapper compares the engine generation immediately before native rendering. The example's AppKit termination handler stops new submissions, calls `fe_session_close`, polls `fe_session_is_idle` without blocking the main thread, and exits after worker completion. The dynamic library remains loaded for the process because ordinary session teardown is asynchronous.

## Native HDR policy

Processed input is explicitly RGBA16F linear BT.2020 in absolute nits. The native renderer applies crop, rotation and pixel aspect, then converts to extended-linear Display P3 and applies the same reference-white/headroom shoulder as [the native harness](hdr-presentation.md). This branch skips the existing YUV transfer decoder and SDR clamps. Current EDR headroom is queried from the window's screen each display tick. Layer colour space and floating-point format describe the pixels actually presented. This video branch writes opaque alpha 1; it does not interpret packed video alpha. Eligible overlays are composited after display mapping by Erika's existing UI pass.

The adapter imports CVMetalTexture views without a CPU pixel copy and retains their owners through completion. It does not infer end-to-end copy or wait counts from that fact; uninstrumented shared-engine operations remain unavailable in reports.

The first completed output in each generation can be captured as binary16 RGBA plus rational-time JSON metadata before display mapping. Capturing deliberately reads completed pixel storage on the CPU; set `ERIKA_FRAME_ENGINE_CAPTURE=none` when measuring throughput without readback.

## Measurement and limitations

The script activates the window by default. `ERIKA_ADAPTER_FOREGROUND=0` leaves smoke runs in the background; a fully occluded window may never present its drawables. Apple defines a zero [`presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime) as unpresented or dropped. Those callbacks are counted separately and never used as display or A/V timestamps.

The adapter uses [shared completed-work measurements](frame-engine.md), reports actual drawable presentation times, and records first-presentation latency after a generation reset. A/V offset is video PTS minus an audio callback clock sampled before encoding and advanced to the actual drawable presentation time at normal playback speed. This estimate does not establish a measured long-duration drift result or rate-change accuracy.

Three retained engine slots bound queued work. At unsustainable model speed, newly decoded frames receive explicit admission backpressure and the last completed output is reused. The prototype does not yet pause audio and video under one enhancement-buffering policy. Admission drops are reported separately because rejected frames never become completed engine samples. Late enhanced overlays are withheld when their timestamps differ from the completed image; synchronized overlay scheduling remains integration work.

The adapter currently requires VideoToolbox frames and explicit supported source colour tags. Software-decoder fallback is rejected rather than silently using an SDR conversion. Frame-level crop, aspect and rotation are supported; stream-only geometry metadata must be checked on representative rotated media. Physical HDR display accuracy, sustained target-hardware performance, and final playback-core qualification require separate evidence.

## Development validation

On 2026-09-10, the self-contained build passed on Apple M3, 16 GB, macOS 26.5. The following local runs used source 320×192, processing 32×24, native drawable 1920×992, reference white 203 nits, maximum luminance ratio 2, and Neural Rendering weights `b6c94e4403d55a0f7308d4521880082fe391efa84d6fbfcfd104b318a854948f`. Three initial completed samples are excluded from warmed metrics. First-output numeric capture was enabled.

| Run | Presenter submission attempts | Completed / admission drops | Warmed completed FPS |
| --- | ---: | ---: | ---: |
| PQ strength 0, 2 s source | 59 | 9 / 50 | 4.50 |
| PQ strength 1, cold and occluded | 60 | 3 / 57 | Unavailable: only warm-up samples |
| HLG strength 0, 2 s source | 118 | 10 / 108 | 4.55 |
| HLG strength 1, 2 s source | 118 | 9 / 109 | 5.34 |
| SDR strength 0, 2 s source | 48 | 10 / 38 | 4.69 |
| Repeated PQ strength 1, 14 s run with seek | 381 | 76 / 302 | 6.17 |

Every completed run exited cleanly with zero engine failures and zero stale completions. The longer run accepted 79 frames, cancelled three at generation changes/shutdown, captured generations 4 and 6, and measured 0.534 s from the final seek-generation reset to first drawable presentation. Its native display reported EDR headroom 16. Shared retained-frame storage peaked at 6,564,288 bytes across three slots; sampled MLX peak active storage was 608,000,948 bytes and sampled process RSS reached 471,351,296 bytes. These are distinct measurements: the 512 MiB session limit bounds retained frame storage, not total model, allocator or process memory.

Before display mapping, bypass PQ maxima were `[1091, 1116, 3806]` nits and HLG maxima `[1068, 1050, 3476]`, agreeing with the native harness. Neural output changed them to `[1160, 956, 2492]` and `[984, 987, 2640]` respectively; all captured components were finite. Numeric captures verify the retained HDR boundary. A foreground screen inspection verified visible native playback and aspect fit; an SDR screenshot cannot verify HDR luminance or colour accuracy.

The longer seek case is reproducible without re-encoding:

```sh
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -y -stream_loop 5 \
  -i assets/test-clips/hdr10-30.mp4 -c copy artifacts/erika-adapter/hdr10-repeat-12s.mp4
ERIKA_ADAPTER_SEEK_AT=4 ERIKA_ADAPTER_SEEK_TO=0.25 ERIKA_ADAPTER_SECONDS=14 \
ERIKA_FRAME_ENGINE_REPORT="$PWD/artifacts/erika-adapter/pq-enhanced-seek.json" \
bash scripts/run-erika-adapter.sh artifacts/erika-adapter/hdr10-repeat-12s.mp4 \
  "$PWD/models/neural-rendering/NeuralRendering.dlssmodel"
```

Reports and captures remain ignored under `artifacts/erika-adapter/`. These short development runs establish the prototype path and expose overload; they do not establish sustainable real-time performance, long-duration A/V drift, or a playback-core winner. In particular, source timing, cold compilation, display dimensions and window visibility differ from CLI-only mpv runs and must be controlled for comparative qualification.
