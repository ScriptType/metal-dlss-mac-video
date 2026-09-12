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

With a model and nonzero strength, the worker gives one decoded input an activation token. Successful submission keeps that token occupied until the presenter selects the matching completed output. The decoded input's timestamp does not advance displayed position. Shared HDR bypass uses the ordinary media clock and no enhancement hold, while retaining a refused input for retry. Both shared-engine paths retain at most one refused worker handoff and one refused presenter upload; they retry before taking another input. Other renderers retain their existing admission policy.

EOF uses a separate output-drain acknowledgment. The worker requests it only after decoded output and its final handoff are exhausted. The presenter checks its channels, retained upload, latest processed output and actual queued PCM. The acknowledgment includes generation, command and output epochs; publication revalidates it under the player state lock. Short final PCM tails can start below the normal prefill threshold when this final-output request proves no more audio will arrive. User pause remains respected.

The renderer's drain condition distinguishes a resolved drawable callback from an actual unavailable presentation-target acquisition. Neither a zero callback nor an unavailable target counts as a positive presentation. The visible native audit independently requires the final source frame's positive drawable timestamp before EOF. This lets hidden playback drain without inventing display evidence. Refusals, successful retries, cancelled retries and unavailable targets have separate counters; an output is marked unpresented only after its callback owners retire.

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

Candidate 3 is Erika commit [`b68885a`](https://github.com/ScriptType/Erika/commit/b68885a188bf01e3ef7fe2481d0685c335e11a5b). Neural visible playback and scripted lifecycle checks remain pending. The [visible zero-strength control](#visible-zero-strength-control) exposes a discarded input and premature EOF. The [capture summary](evidence/m3-erika-enhancement-hold.json) and [all 689 completed frames](evidence/m3-erika-enhancement-hold.csv) preserve the baseline and three candidates, including failures and unavailable observations.

The transport change passed 75 focused CPU tests, two native-demo schedule parser tests, and the native build. Regressions cover activation ownership, pause and seek intent, quantized PCM consumption, temporary audio gaps, delayed feedback across internal pauses, and ordered catch-up without restarting audio. Native captures use the same shared engine (`9f0c58fa…`), PQ/30-fps source, weights, 160×96 processing and 960×496 drawable. Exact source patches, executables, logs and reports remain in `artifacts/erika-overload-hold-1/`.

Reproduce the focused CPU checks, schedule parser checks and native-demo build after preparing Erika's native dependencies:

```sh
bash scripts/test-erika-transport.sh
```

The script compiles the actual `shared-hdr` feature and uses software decoding and buffered PCM in the selected tests. It does not load the shared MLX engine, perform inference or open a native window. The separate Erika CI job uses Erika's native dependency build and runs the same script; passing this job does not qualify visible playback or the pending native lifecycle checks.

| Capture | Completed / warmed | Admission refusals | Maximum absolute activation/audio offset | Native visibility |
|---|---:|---:|---:|---|
| Original transport, current shared engine | 169 / 166 | 703 | Unavailable | Pass |
| Candidate 1 | 163 / 160 | 0 | 247.0 ms | Pass |
| Candidate 2 | 184 / 181 | 0 | 175.0 ms | Fail |
| Candidate 3 | 173 / 170 | 0 | 13.1 ms | Fail |

Activation offsets apply the plan's 20-ms diagnostic target to non-warmup, same-generation activation events and actual audio ring-clock samples. They are separate from the retained last-redraw estimates above and mpv's cached queue samples. Every completed frame remains in the reports. Candidate 1 accumulated video lead while using wall time between short audio slices. Candidate 2 exposed a recovery bug in which repeated internal pauses erased the evidence of resumed audio consumption. Both failures are retained.

Candidate 3 passed its activation/audio timing check, with no admission refusals and at most two retained slots (5,777,024 bytes). Its measured window was entirely occluded, so no positive drawable callback or visible presentation qualification is available. These bounded captures do not establish a causal throughput improvement, physical synchronization, source-rate Live, sustained playback or final M5 core selection.

## Visible zero-strength control

The eight-second control on 2026-09-12 uses candidate 3's archived executable and shared engine, the same PQ/30-fps source, 160×96 processing and 960×496 drawable. It pauses at two seconds, seeks to 59.733 seconds while paused, and resumes at four seconds. The [evidence](evidence/m3-erika-zero-control.json) includes all 45 completed frames and the transport audit. Read-only session/display/window observations pass, as does the frozen runner's full warmed-interval visibility check. No physical HDR or scanout acceptance follows from window metadata or drawable callbacks.

The transport audit passes 362 of 364 checks. All completed frames report zero inference, motion and reserved model payload; the asynchronous video clock remains disabled. Paused seeking presents the requested new-generation preview, and the software audio queue eventually drains with stable read counts. Two failures prevent qualification:

- At startup, the three retained engine slots fill and one decoded input is refused. The bypass presenter discards that input instead of retaining it for retry.
- EOF is observed at host time 1212763.6108968337, with 7,183 audio frames still queued (149.646 ms). Final source PTS 59.967 completes 4.069 ms later and first presents 39.268 ms after that EOF observation. The image is eventually presented; EOF precedes output completion.

The capture, observer and standalone audit are preserved separately, including the audit failure. The monitor performs no permission request or pixel capture. This is a native Metal/VideoToolbox control with zero neural work; it does not qualify neural lifecycle, source-rate Live, physical synchronization or M5 performance. Reported drop flags also include outputs marked before delayed positive presentation callbacks, so those flags alone do not count physically missing images.

Erika [`5aeb067`](https://github.com/ScriptType/Erika/commit/5aeb067b101adcd950f8443c3b7afc21d9417573) adds the retry and EOF-drain contracts above. All 91 focused CPU tests, two schedule-parser tests and the native build pass. Regressions cover bounded retry ownership, stale acknowledgments, output resets, suspended video, video-only final intervals, short PCM tails and paused seeks beyond the final frame. The shared engine remains unchanged.

The [corrected visible control](evidence/m3-erika-bypass-drain.json) passes all 348 transport checks. It completes all 42 admitted inputs: 24 full-engine refusal attempts are resolved by nine subsequently accepted retries, with no admission drops or cancelled retries. Four completed outputs are never presented, two of them warmed; the passing control does not establish display of every decoded frame. Inference, motion and reserved model payload remain zero, and the asynchronous video clock remains disabled.

Final PTS 59.967 first presents 192.604 ms before the first observed EOF, whose software audio queue is already empty. Paused seeking presents the requested preview without starting playback. The eight-second capture passes native visibility, retains all input/runtime pins, and peaks at 158,449,664 bytes sampled process-tree RSS. Its scripted duration and redraw estimates do not establish playback throughput or physical synchronization.

## Visible neural transport and lifecycle

The [34-second neural capture](evidence/m3-erika-matched-visible.json) uses the corrected Erika executable and the same archived engine, model, source and dimensions as the zero-strength control. Native visibility and all 1,381 transport checks pass. All 167 completed outputs have positive drawable presentation timestamps; 164 steady activation/audio observations remain within 19.021 ms of the plan's 20-ms diagnostic target. The capture retains all frames, activation links and separately sampled audio clocks. Three zero-time drawable callbacks precede the first frame's positive callback.

No input admission is refused or dropped, and the engine retains at most two slots (5,777,024 bytes). The measured seek latency is 4.807 seconds. These observations qualify this bounded visible transport case; they do not establish a causal performance gain, physical synchronization, source-rate Live operation or final core selection on M5.

The [first 45-second lifecycle capture](evidence/m3-erika-lifecycle-missed-pause.json) passes native visibility and 1,074 of 1,076 transport checks. Its initial pause at two seconds occurs after the last in-flight completion, missing the required completion and activation while paused. The existing displayed frame correctly prevents a future frame from activating during that pause. Paused seek preview, explicit resume, audio-only playback, foreground recovery and final output/audio drain checks pass. The complete failed audit remains recorded.

A prospective schedule amendment moves only that initial pause to 0.5 seconds and preserves the auditor byte for byte. This captures both missing pause witnesses, but one EOF snapshot combines running playback flags with a later EOF read. The demo samples those fields under separate locks; coherent playback telemetry and its native validation remain pending. Neither lifecycle attempt is accepted as a complete pass.

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
