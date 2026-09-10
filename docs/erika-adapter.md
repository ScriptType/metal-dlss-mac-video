# Erika shared HDR adapter

The optional `shared-hdr` feature inserts the shared frame engine between Erika's VideoToolbox decoder and its native Metal renderer. Neural processing uses an asynchronous presentation contract with an internal audio/video hold. It remains a comparison prototype; source-rate Live qualification and final playback-core selection require separate evidence.

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

With a model and nonzero strength, the worker gives one decoded input an activation token. Successful submission keeps that token occupied until the presenter selects the matching completed output. A full presenter channel or engine retains the same input for retry. The decoded input's timestamp does not advance displayed position. Ordinary renderers and zero-strength bypass retain their existing scheduling contract.

Presenter generations invalidate pending/completed output on seeks, source changes and transitions. The wrapper compares the engine generation immediately before native rendering. The example's AppKit termination handler stops new submissions, calls `fe_session_close`, polls `fe_session_is_idle` without blocking the main thread, and exits after worker completion. The dynamic library remains loaded for the process because ordinary session teardown is asynchronous.

## Native HDR policy

Processed input is explicitly RGBA16F linear BT.2020 in absolute nits. The native renderer applies crop, rotation and pixel aspect, then converts to extended-linear Display P3 and applies the same reference-white/headroom shoulder as [the native harness](hdr-presentation.md). This branch skips the existing YUV transfer decoder and SDR clamps. Current EDR headroom is queried from the window's screen each display tick. Layer colour space and floating-point format describe the pixels actually presented. This video branch writes opaque alpha 1; it does not interpret packed video alpha. Eligible overlays are composited after display mapping by Erika's existing UI pass.

The adapter imports CVMetalTexture views without a CPU pixel copy and retains their owners through completion. It does not infer end-to-end copy or wait counts from that fact; uninstrumented shared-engine operations remain unavailable in reports.

The first completed output in each generation can be captured as binary16 RGBA plus rational-time JSON metadata before display mapping. Capturing deliberately reads completed pixel storage on the CPU; set `ERIKA_FRAME_ENGINE_CAPTURE=none` when measuring throughput without readback.

## Measurement and limitations

The script activates the window and enables bounded presentation diagnostics by default. `ERIKA_ADAPTER_FOREGROUND=0` leaves smoke runs in the background; a fully occluded window may never present its drawables. Apple defines a zero [`presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime) as unpresented or skipped. Those notifications are counted separately and never used as display or A/V timestamps. They are received callbacks, not missing handlers.

`ERIKA_ADAPTER_DIAGNOSTICS=1` records actual native window state on transitions and at least once per second while the main loop advances. The `.native.log` includes visibility, occlusion, minimization, activation, window identity, drawable extent and layer configuration. The `.adapter.json` adds lifetime draw/GPU/presentation counters, the last 120 host-second buckets, the first eight positive and zero callbacks, and the most recent 16 callbacks. This instrumentation does not change rendering or clock policy. `ERIKA_ADAPTER_DIAGNOSTICS=0` disables it.

`ERIKA_ADAPTER_REQUIRE_VISIBLE=1` additionally writes a `.visibility.json` and exits with status 2 when actual visibility coverage is insufficient. It checks the entire interval from the first warmed frame's submission through the last warmed completion; a truncated retained-frame inventory is ineligible. Every observed state must be visible, occlusion-visible and unminimized with the same native window identity, with an initial state and no observation gap longer than 1.5 seconds. Activation and focus are recorded separately. Native occlusion-visible state establishes that some part of the window is visible; it does not measure the visible area or physical scanout. All completed work and zero timestamps remain in reports even when the visibility gate fails.

The adapter uses [shared completed-work measurements](frame-engine.md), reports actual drawable presentation times, and records first-presentation latency after a generation reset. A/V offset is video PTS minus an audio callback clock sampled before encoding, extrapolated to the drawable callback at the sampled playback rate or zero while held. Transport changes after the sample are not reconstructed. The retained `presentedHostSeconds` is the first positive callback for a completed frame, while `avOffsetSeconds` is updated on later positive redraws; those fields do not form an atomic first-presentation sample. This estimate does not establish physical synchronization or a long-duration drift result.

Three retained engine slots bound queued work. Neural processing also limits the worker to one input awaiting activation. When the next completed output is unavailable at the current frame's deadline, the presenter pauses audio and the media clock while retaining queued PCM and the current image. User pause remains a separate intent. A future completed output permits the current interval to finish before activation. Frame PTS and durations retain their source values. Admission refusals are separate from engine drops because rejected frames never become completed engine samples. Late enhanced overlays are withheld when their timestamps differ from the completed image.

Activation follows the audio output's read cursor. Temporary audio gaps permit a bounded fallback clock; queued PCM alone does not establish resumed consumption. Enhancement holds preserve audio read continuity, while output resets invalidate it. A late frame whose interval has already ended keeps audio held while ordered video frames catch up. These presenter controls cannot service a deadline while the render thread itself is blocked.

The adapter currently requires VideoToolbox frames and explicit supported source colour tags. Software-decoder fallback is rejected rather than silently using an SDR conversion. Frame-level crop, aspect and rotation are supported; stream-only geometry metadata must be checked on representative rotated media. Physical HDR display accuracy, sustained target-hardware performance, and final playback-core qualification require separate evidence.

## Scripted transport checks

The native demo accepts `ERIKA_ADAPTER_ACTIONS` as an ordered JSON array of `pause`, `play`, `seek`, `audio-only` and `foreground` requests. Each action has an `at` time in seconds from native view creation; `seek` also requires `seconds`. A schedule requires a smoke duration of at most 600 seconds, permits at most 64 actions, and rejects invalid input before opening the window.

For example, this sequence pauses during startup, seeks while paused, resumes, enters the actual audio-only presenter route, returns to rendering, and seeks to the final eight video frames:

```sh
ERIKA_ADAPTER_ACTIONS='[{"at":2,"action":"pause"},{"at":15,"action":"seek","seconds":0.73},{"at":21,"action":"play"},{"at":26,"action":"audio-only"},{"at":29,"action":"foreground"},{"at":35,"action":"seek","seconds":59.733}]' \
ERIKA_ADAPTER_SECONDS=45 ERIKA_ADAPTER_MUTE=1 \
ERIKA_FRAME_ENGINE_WIDTH=160 ERIKA_FRAME_ENGINE_HEIGHT=96 \
ERIKA_ADAPTER_DISPLAY_WIDTH=960 ERIKA_ADAPTER_DISPLAY_HEIGHT=496 \
ERIKA_FRAME_ENGINE_CAPTURE=none \
ERIKA_FRAME_ENGINE_REPORT="$PWD/artifacts/erika-transport-repeat/report.json" \
bash scripts/run-erika-adapter.sh assets/test-clips/playback/pq-30-60s.mkv \
  "$PWD/models/neural-rendering/NeuralRendering.dlssmodel"
```

`ERIKA_ADAPTER_TRANSPORT` records each request's result and up to ten snapshots per second, capped at 6,000 snapshots. Snapshots include player intent, running clock, generation, the actual EOF flag, audio read/write/queue/underflow counters, and failures. A successful request establishes acceptance of the call; subsequent observations establish the transition. Smoke termination alone does not establish EOF. The `audio-only` action changes the presenter route; covering the window is a separate visibility test.

With `ERIKA_ADAPTER_DIAGNOSTICS=1`, `enhancement_transport` records hold/release and activation events with actual audio samples and monotonic host time. These records describe feedback enqueued to the worker. They do not measure physical audio output or display scanout. The control schedule is opt-in and does not change ordinary interactive controls.

## Enhancement hold validation on M3

Candidate 3 is Erika commit [`b68885a`](https://github.com/ScriptType/Erika/commit/b68885a188bf01e3ef7fe2481d0685c335e11a5b). Its visible playback, scripted native lifecycle and zero-strength native checks remain pending. The [capture summary](evidence/m3-erika-enhancement-hold.json) and [all 689 completed frames](evidence/m3-erika-enhancement-hold.csv) preserve the baseline and three candidates, including failures and unavailable observations.

The transport change passed 75 focused CPU tests, two native-demo schedule parser tests, and the native build. Regressions cover activation ownership, pause and seek intent, quantized PCM consumption, temporary audio gaps, delayed feedback across internal pauses, and ordered catch-up without restarting audio. Native captures use the same shared engine (`9f0c58fa…`), PQ/30-fps source, weights, 160×96 processing and 960×496 drawable. Exact source patches, executables, logs and reports remain in `artifacts/erika-overload-hold-1/`.

Reproduce the focused CPU and parser checks after the build setup above:

```sh
source scripts/env.sh
cargo test --locked --manifest-path vendor/Erika/Cargo.toml --jobs 2 \
  -p erika --features shared-hdr --lib -- --test-threads=1 \
  enhancement_ playback::tests::playback_fixture_ playback::tests::buffering_ \
  playback::tests::audio_only_mode playback::tests::playback_clock_ \
  core::tests::frame_output_ core::tests::pause_publishes_ core::tests::failed_pause_ \
  core::tests::buffering_ core::tests::stale_worker_generation_ core::tests::newer_command_ \
  presenter::tests::video_frame_backpressure_ core::tests::audio_observation_ core::tests::audio_capture_
cargo test --locked --manifest-path vendor/Erika/Cargo.toml --jobs 2 \
  -p macos_native_demo --features shared-hdr adapter_schedule -- --test-threads=1
```

| Capture | Completed / warmed | Admission refusals | Maximum absolute activation/audio offset | Native visibility |
|---|---:|---:|---:|---|
| Original transport, current shared engine | 169 / 166 | 703 | Unavailable | Pass |
| Candidate 1 | 163 / 160 | 0 | 247.0 ms | Pass |
| Candidate 2 | 184 / 181 | 0 | 175.0 ms | Fail |
| Candidate 3 | 173 / 170 | 0 | 13.1 ms | Fail |

Activation offsets apply the plan's 20-ms diagnostic target to non-warmup, same-generation activation events and actual audio ring-clock samples. They are separate from the retained last-redraw estimates above and mpv's cached queue samples. Every completed frame remains in the reports. Candidate 1 accumulated video lead while using wall time between short audio slices. Candidate 2 exposed a recovery bug in which repeated internal pauses erased the evidence of resumed audio consumption. Both failures are retained.

Candidate 3 passed its activation/audio timing check, with no admission refusals and at most two retained slots (5,777,024 bytes). Its measured window was entirely occluded, so no positive drawable callback or visible presentation qualification is available. These bounded captures do not establish a causal throughput improvement, physical synchronization, source-rate Live, sustained playback or final M5 core selection.

## Development validation before synchronized enhancement holds

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

The [alternating M3 capture](adapter-comparison.md) uses matched source/model/processing/drawable dimensions and app-muted audio. Its mostly skipped drawable presentations prevent a final presentation comparison; the captured limits remain explicit.

## Controlled presentation diagnostics

Two ten-second neural runs used the same 320×192 PQ source, 160×96 processing, 960×496 drawable and recorded source/weights/runtime hashes. A diagnostic-only opaque window covered the playback window for three seconds in the second run while its render timer continued. The [compact evidence](evidence/m3-erika-presentation-diagnostics.json) retains exact binary/source hashes, actual window observations, callback buckets and report checksums; source changes were uncommitted during capture.

| Case | Completed / warmed | Successful GPU commands | Positive / zero presentation callbacks | Warmed A/V samples |
|---|---:|---:|---:|---:|
| Visible neural playback | 52 / 49 | 527 | 526 / 1 startup skip | 49 |
| Three-second occlusion | 62 / 59 | 545 | 365 / 180 | 38 |

All GPU commands succeeded, with no stale callbacks. Full occlusion produced 60 zero timestamps per second, and positive presentations resumed when the cover was removed. Losing foreground activation while remaining occlusion-visible did not interrupt positive presentation callbacks. A separate original-only visible run completed 286 frames with 578 positive callbacks and no zero timestamps.

The visible neural run still had video-minus-audio estimates from −625 to −338 ms, median −433 ms. These measurements expose the existing overload clock policy; they do not qualify synchronized playback. Historical comparison logs lacked window state, so their skipped presentations cannot be attributed conclusively to occlusion. Their positive-plus-zero counts account for every HDR draw, which rules out missing callback delivery in those reports. No renderer, layer-attachment or ownership correction was justified by the controlled evidence.

Reproduce without rebuilding the shared engine:

```sh
python3 scripts/test-erika-presentation.py --strength 1 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --output artifacts/erika-presentation-repeat
```

Use current diagnostic-enabled Erika binaries and a new output directory. The harness validates full run duration plus observed occlusion and reveal. An earlier `orderOut` experiment exited after three seconds because it removed the final window; its incomplete hidden/reveal case is explicitly excluded from the evidence.
