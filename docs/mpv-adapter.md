# mpv shared HDR engine adapter

The `metal-hdr` video filter submits immutable VideoToolbox NV12/P010 frames to the shared C engine and returns completed RGBA16F hardware frames to `gpu-next`. Native macvk embedding accepts an in-process `NSView` pointer through `wid`; the host retains that view until libmpv destruction. See [the shared engine contract](frame-engine.md) for source colour units, model loading and session ownership.

## Build and run

```sh
bash scripts/build-mpv-adapter.sh
artifacts/mpv-build/mpv --no-config \
  --vo=gpu-next --gpu-api=vulkan --gpu-context=macvk \
  --target-colorspace-hint=yes --hwdec=videotoolbox \
  --vf=metal-hdr:strength=0:policy=adaptive \
  assets/test-clips/hdr10-30.mp4
```

The build enables mpv's optional `frame-engine` Meson feature using a local pkg-config file. The feature is disabled in an ordinary upstream build. The shared engine dylib and its MLX runtime kernels must be available before starting mpv; the build script prepares the runtime and links the required rpath.

For neural output, set `model` to a verified `.dlssmodel` package and specify processing dimensions:

```sh
artifacts/mpv-build/mpv --no-config \
  --vo=gpu-next --gpu-api=vulkan --gpu-context=macvk \
  --target-colorspace-hint=yes --hwdec=videotoolbox \
  --vf=metal-hdr:model=models/neural-rendering/NeuralRendering.dlssmodel:processing-width=32:processing-height=24:strength=1:maximum-luminance-ratio=2:policy=adaptive \
  assets/test-clips/hdr10-30.mp4
```

The tiny 32×24 processing shape validates neural integration on M3. It is not a useful quality or sustainable Live preset. The source and presentation dimensions remain independent of processing dimensions.

| Filter option | Default | Meaning |
|---|---|---|
| `model` | None | Package path; no package selects the engine's HDR original path |
| `processing-width`, `processing-height` | 320, 192 | Neural processing dimensions |
| `strength`, `colour-strength` | 1, 1 | Reconstruction controls |
| `reference-white` | 203 | Reference white in nits |
| `hlg-peak` | 1000 | HLG display peak used for the OOTF |
| `maximum-luminance-ratio` | 2 | Reconstruction gain bound |
| `bypass` | `no` | Forward the decoder's original hardware frames directly |
| `policy` | `direct` | `adaptive` buffers both playback clocks under enhancement pressure; `direct` is the unpaced processor diagnostic |
| `measurements` | None | JSONL filter-output and normalization-pass measurements |
| `measurement-config` | None | Path to the shared engine's `MeasurementConfiguration` JSON |
| `engine-report` | None | Destination for shared engine JSON measurements at teardown |
| `prepared-config` | None | Path to the source-bound Prepared request JSON |
| `prepare` | `no` | Start or resume preparation when constructing a Prepared filter |

`vf-command <filter-label> bypass yes` / `no` switches decoder bypass while retaining the engine/model session and resetting temporal history. Effect and processing-size changes require rebuilding the filter configuration; the native host performs that work off AppKit and reports the model reload and temporal reset.

## Playback policy and comparison

`vf-command enhance policy adaptive` enables a shared buffering policy in mpv's playback core. When the next processed frame is unavailable, mpv requests a shared audio/video hold at the displayed frame's deadline. The measured CoreAudio pull path starts that hold earlier to account for its clock advancing briefly after a reset-based pause. Other audio outputs retain the ordinary deadline. The decoder/filter graph continues filling its bounded slots while controls remain responsive. Completed video resumes both clocks. Adaptive disables decoder/render frame dropping; it preserves source timestamps and HDR interpretation while effective playback throughput can be below the source rate. Processing dimensions and effect settings are explicit and independent of the presentation size.

`vf-command enhance policy live` succeeds only after this immutable neural session has at least 60 warmed completions, excludes three cold completions, and has p95 completed latency below 80% of the source-frame period. The minimum processing shape is 320×192; tiny instrumentation shapes and strength-zero paths cannot qualify. The qualification belongs to the current model, settings, source dimensions/rate and Metal device. Seeks, source changes and configuration replacement invalidate it. Losing the measured margin switches Live to Adaptive visibly. No current M3 neural configuration has been qualified as Live.

On startup and seek, decoder preroll reaches mpv's exact-seek selector without inference. The selected source frame appears first, while its enhancement runs. Both clocks stay held until the renderer replaces that frame with enhanced pixels of exactly the same rational PTS and generation. A superseded generation cannot replace the current frame. Source preview admission does not wait for obsolete inference to finish.

`vf-command enhance compare original` / `enhanced` switches an immutable retained pair while the user has paused playback. The renderer changes its current image and colour interpretation, flushes the old image cache and redraws without advancing PTS or submitting temporal work. The command rejects missing pairs and playback that is not paused. Original PQ/HLG source buffers retain their metadata; enhanced buffers remain linear BT.2020 RGBA16F.

libmpv clients can read or observe the `enhancement-state` node:

| Fields | Meaning |
|---|---|
| `policy`, `buffering`, `preview-pending` | Current mode and shared-clock/seek pressure |
| `live-qualified`, `warmed-samples`, `completed-p95-seconds`, `source-fps` | Conservative runtime qualification evidence |
| `processing-width`, `processing-height`, `strength`, `colour-strength` | Effective explicit quality configuration |
| `source-width`, `source-height`, `model`, `hardware` | Session configuration identity |
| `pending-frames`, `submitted-frames`, `completed-frames` | Bounded admission and completion counters |
| `buffer-count`, `buffer-seconds` | Shared-clock buffering accumulated during playback |
| `compare-ready`, `comparison` | Availability and displayed member of the paused pair |
| `generation`, `displayed-generation`, `displayed-source-pts`, `displayed-timebase-num`, `displayed-timebase-den` | Exact displayed source identity |
| `displayed-content-kind` | Immutable output provenance: `unknown`, `original`, `enhanced`, `prepared-original`, or `prepared-enhanced` |
| `prepared-supported`, `prepared` | Compiled Prepared capability and its context's current progress node |

## Prepared playback

The filter owns one shared preparation/playback context selected by `prepared-config`. The request identifies a local source, cache directory and disk capacity. For example:

```json
{
  "sourcePath": "/absolute/movie.mp4",
  "cacheDirectory": "/absolute/hdr-cache",
  "capacityBytes": 8589934592,
  "rangeStart": {"value": 0, "timescale": 30},
  "rangeEnd": {"value": 6, "timescale": 30},
  "segmentFrames": 3,
  "prerollFrames": 1
}
```

Omitting both range fields selects the whole video; defaults are 60 frames per segment and eight frames of preroll. Processing/model/effect options come from the same filter configuration and are included in cache identity. mpv supplies the actual selected demuxer's filename to the shared C API, which compares its canonical local path with `sourcePath`. A different source, nonlocal input or video track other than the first video stream is rejected. A second filter cannot silently read a first-track cache for another track.

Preparation opens a separate instance of the actual playback demuxer (`mkv` or `lavf`) and feeds its packets into an independent FFmpeg VideoToolbox decoder on the preparation utility queue. It never drives the active playback graph from that queue. Using the same demuxer preserves native Matroska's explicit `BlockDuration` and missing-duration distinction; reopening every source through libavformat could synthesize a different rounded duration. The provider applies the opened core's timestamp offset and the same packet/timebase conversion and source descriptor logic as live decoding. Its semantic identifier, source hash and exact decoded timing inventory belong to cache identity.

Inventory scanning decodes one frame at a time and retains timing records rather than video pixels. Segment readers seek to an earlier keyframe, decode through exact preroll and emit the requested range. Cancellation interrupts each reader's independent I/O; close drains its FFmpeg/VideoToolbox state. Borrowed CVPixelBuffers remain owned until the engine has synchronously retained them. The standalone FrameEngine harness keeps its separate AVFoundation provider; mpv Prepared playback uses the selected core provider without a silent decoder fallback.

`vf-command enhance prepare start` starts or resumes preparation; `cancel` stops future work while keeping committed ranges reusable. `enhancement-state.prepared` exposes `configurationState`, `jobState`, `completedSegments`, `totalSegments`, `processedFrames`, `reusedSegments`, `completedRanges`, `availableRanges`, `cacheHits`, `cacheMisses` and any `error`. The successful terminal job state is `complete`. `availableRanges` describes the current committed index; historical completion can include ranges already evicted by the disk budget. Acquisition still validates data and pins active readers.

Cache lookup uses exact source PTS and duration. A miss returns the HDR original through the same output lease and renderer path. The displayed frame's immutable `displayed-content-kind` distinguishes a cached enhanced frame from original fallback; the progress node's `lastOutput` describes background processing and must not label the currently displayed frame. `prepared-original` explicitly identifies a cached zero-strength reference. Prepared cache speed never qualifies neural Live mode.

The current float reference cache reads Float32 pixels from disk and packs a CPU-complete RGBA16F IOSurface before native hardware import. Measurements expose cache-read and packing wall time. This path preserves linear HDR precision; the separately evaluated HDR10 codec policy is not yet the production cache backend.

## Timing, cancellation and ownership

The FFmpeg decoder retains its original integer timestamp, duration and rational timebase in `mp_image`, alongside mpv's playback-clock timestamps. Copies preserve those fields without a floating-point round trip. The filter rejects missing rational timing or an upstream filter that changed the timeline without supplying corresponding rational timing. Supported SDR/PQ/HLG colour metadata is translated explicitly; Dolby Vision's reshaping path is not inferred from PQ.

The engine keeps three admitted slots. The filter retains at most three original frame references for matching completed outputs by frame identity. It applies backpressure through mpv's existing pins; it does not build an unbounded inference queue. A worker polls outstanding engine/Metal work at two-millisecond intervals and wakes the filter graph on completion. When no work is outstanding, it sleeps on a condition variable. Inference never runs in a render hook or on AppKit's thread.

Seeks and input geometry/colour discontinuities reset the engine generation and clear pending references. Output images carry a reference-counted atomic generation shared with the filter. `gpu-next` checks that generation at draw entry and immediately before rendering all contributing frames, including queued copies. A normal missed presentation deadline does not reset temporal state. mpv retains responsibility for audio playback, playback-clock scheduling, frame dropping and redraws.

The engine's completed buffer contains absolute-nit RGB. Libplacebo's linear working domain uses 1.0 = 203 nits, so the adapter performs one explicit Metal normalization pass into a bounded six-buffer RGBA16F pool. It preserves negative values and HDR headroom. A threadgroup reduction measures transformed peak luminance; reading that four-byte scalar after command completion supplies output peak metadata. Source-only ICC, Dolby Vision, film-grain and dynamic HDR metadata are cleared from transformed pixels.

Native macvk output preserves the supplied linear BT.2020 target range and explicitly describes float unity as 203 nits with public Core Animation HDR metadata. It completes pending Vulkan color recreation and validates RGBA16F/extended-linear BT.2020/EDR before assigning metadata, ahead of drawable acquisition. Metadata ownership stays on the renderer thread; display/profile/backing changes request a refresh without a synchronous AppKit call per frame. Original PQ/HLG transitions return metadata ownership to Vulkan, and original SDR clears stale HDR metadata. The [native color audit](native-hdr-color-audit.md) records ten successful metadata transitions and the separate, still-open requirement for a compositor comparison with stable visibility. No physical HDR calibration is claimed.

The VideoToolbox mapper imports packed float Metal textures through libplacebo's existing `PL_HANDLE_MTL_TEX` path. The mapper permits floating-point textures and uses packed-buffer dimensions for RGBA16F. The direct decoder/neural adapter path performs no CPU pixel upload/download. Resource counts include one full-frame GPU normalization pass and one four-byte CPU peak readback per output; Prepared additionally performs its documented disk read and Float32-to-RGBA16F packing. Import and rendering follow libplacebo's retained texture lifetimes.

Shutdown closes session admission, cancels pending generations, drains the final normalization command and waits for actual engine idleness on mpv's core thread before destroying the session. AppKit remains responsive because the native host runs libmpv calls on its worker. Process or dylib teardown must not race MLX's global Metal resource destruction.

## Measurements and checks

```sh
source scripts/env.sh
meson test -C artifacts/mpv-build image-generation --print-errorlogs
bash scripts/build-mpv-host.sh
artifacts/mpv-host/MpvHDRHost assets/test-clips/hdr10-30.mp4 \
  --seconds 9 --report artifacts/mpv-embedded-pq.json
```

The generation test covers integer timestamps beyond double's exact-integer range, rational-duration propagation, source destruction, cancellation of retained/copied images, mismatched-pair rejection and retained variant pixel identity. `scripts/test-mpv-policy.py` drives accurate rapid seeks, six paused comparison toggles, Live rejection and controlled Adaptive playback through JSON IPC. It disables unrelated native key bindings, verifies the actual drawable, captures engine allocator/resident measurements, and reports the 20-ms A/V target separately from functional checks. The native host additionally checks that a single embedded child surface uses Metal/EDR and exercises resize/fullscreen/teardown. These snapshots describe native configuration rather than calibrated physical display accuracy.

`measurements` records completed filter output, exact PTS, host timestamps, the completed normalization GPU interval and measured peak nits. It is not an onscreen presentation measurement. `engine-report` records the shared processor's queue, completed-work and allocator measurements. Without `measurement-config`, source/power settings are labeled unreported, and display dimensions are the physical screen reported by mpv, not the drawable. Matched comparison runs must supply actual drawable dimensions, source/model identities, display and power settings.

The initial M3 PQ neural probe used a 320×192 source, 32×24 processing, strength 1, 203-nit reference white and a gain bound of 2. It completed 32 frames, with 29 warmed samples: 8.92 completed frames/s, 103.96 ms median and 163.35 ms p95 completed work. The filter stayed at three engine slots. Those timings establish functioning neural processing and expose that this configuration cannot sustain a 30-fps source. They do not qualify Live mode, audio synchronization, temporal quality or the final core selection.

The controlled Adaptive run used a continuous 20-second PQ/30-fps clip with sine audio, the same 320×192 source and 32×24 neural processing, a verified 960×496 drawable, muted CoreAudio and an 18-second wall interval. It completed 171 outputs, including 167 warmed samples at 9.45 completed frames/s. Steady samples after the first two seconds measured 4 ms median A/V offset, 8 ms p95 absolute offset and 9.33 ms maximum absolute offset, with no unexpected generation changes. Both clocks buffered for 13.57 seconds across startup, seeks and playback; this is synchronized Adaptive playback below the source rate.

The coalesced final seek selected 0.7 seconds: its original appeared in renderer-current observations at 56.97 ms and the same-PTS enhanced pair at 911.88 ms. Six paused toggles alternated PQ source and linear enhanced interpretation without changing PTS, generation or submission count. Live was rejected. The sampled pending count stayed at two; the engine permits three frame slots. Sampled process RSS peaked at 594,657,280 bytes, MLX active at 305,185,928 bytes, cache at 355,415,558 bytes and allocator peak-active at 608,000,948 bytes. These are observations, not memory limits.

Evidence is in `artifacts/mpv-policy-pq-controlled-neural.json`, `.engine.json` and `.configuration.json`. The configuration records source/weight hashes, drawable verification and the power snapshot. A/V comes from mpv's audio clock property; preview latency observes renderer-current state rather than physical scanout. A separate Matroska smoke verifies nominal 1/30-second duration when the decoder PTS scale cannot represent it exactly. Older loop-remux or native-keyboard-interrupted runs are not controlled drift evidence.

`python3 scripts/test-mpv-prepared.py --model models/neural-rendering/NeuralRendering.dlssmodel --report artifacts/mpv-prepared-neural-smoke.json` passed with real neural processing. The first process prepared six frames in two segments; seeking to 0.1 seconds displayed an exact cache hit labeled `prepared-enhanced`, and 0.7 seconds displayed an original miss. A second process reused both segments and processed zero frames. Both exited cleanly, and source-mismatch/second-video guards rejected unsafe configurations. The image-generation unit test also verifies immutable provenance across retained pair switches.

The independent source-core provider subsequently passed real neural tests on MP4, native Matroska and variable-rate Matroska. The script now chooses its first six frames and hit/miss requests from exact source timestamps, allowing different rates and timestamp gaps. MP4 and Matroska prepared `[0, 1/5)`; variable-rate Matroska prepared `[0, 267/1000)`, hit at `133/1000` and returned the correct original outside coverage at `467/1000`. Each second process reused both completed segments with zero processing. The variable-rate test cancelled after one processed frame with no completed range published, then resumed to six complete outputs. All six playback processes exited cleanly and source/track guards passed.

```sh
python3 scripts/test-mpv-prepared.py --model models/neural-rendering/NeuralRendering.dlssmodel --report artifacts/mpv-prepared-provider-mp4.json
python3 scripts/test-mpv-prepared.py --source assets/test-clips/playback/pq-30-30s.mkv --model models/neural-rendering/NeuralRendering.dlssmodel --report artifacts/mpv-prepared-provider-mkv.json
python3 scripts/test-mpv-prepared.py --source assets/test-clips/playback/pq-30-vfr-30s.mkv --model models/neural-rendering/NeuralRendering.dlssmodel --cancel-first --report artifacts/mpv-prepared-provider-vfr.json
```

The nine-second embedded HLG model smoke passed with the same processing dimensions and gain bound. It exercised exact seeks, pause/resume, resize, fullscreen and teardown. The surface reached RGBA16F with extended linear BT.2020 and EDR enabled; no renderer-owned window appeared, and removing the renderer left the host window alive. The report recorded ten dropped frames and a 1.172-second maximum absolute A/V offset including startup and lifecycle actions. This proves the embedding and shutdown path, while leaving sustained pacing unqualified. The machine-readable report is `artifacts/mpv-hdr-host-hlg-model.json`.

Sustained neural Live qualification, longer drift runs and physical presentation measurements remain acceptance work; absent metrics are reported as unavailable. Current development measurements target M3.

### Continuous M3 clock checks

The broader fixtures contain continuous PCM pulses, alternate audio, styled ASS subtitles, chapters and long GOPs. The first three Adaptive cases each used 30 seconds of wall playback after the seek/compare checks, with a 320×192 source, 32×24 neural processing, strength 1, reference white 203 nits, gain bound 2, a 960×496 native Vulkan swapchain and muted CoreAudio. They ran sequentially on battery power. All exited cleanly, retained exact source identity through six paused comparison switches, observed zero decoder/VO drops and stale generations, and sampled at most two pending frames.

| Source | Completed / warmed frames | Completed fps | Steady A/V median / p95 absolute / maximum absolute | Playback buffering | Original preview / enhanced pair |
|---|---:|---:|---:|---:|---:|
| SDR 24 fps | 281 / 277 | 9.41 | 4 / 8 / 9.33 ms | 18.66 s, 279 episodes | 83 / 927 ms |
| HLG 60 fps | 343 / 339 | 11.36 | 3 / 7.33 / 22 ms | 24.60 s, 341 episodes | 78 / 621 ms |
| PQ variable rate, nominal 30 fps | 268 / 264 | 8.89 | 2.67 / 9.33 / 20.33 ms | 19.20 s, 266 episodes | 89 / 1061 ms |

The HLG run exceeded the 20-ms target for one displayed frame at source PTS 4.583 seconds, observed in three consecutive samples. PQ variable-rate playback exceeded it at 8 seconds in four samples. Neither showed cumulative drift: the last-quarter median differed from the first by approximately −0.33 ms in every case. These are functional passes with two clock-target failures, so broader timing acceptance remains open. Those failures motivated the readiness checks below. No tested neural configuration qualified Live; actual qualified-Live deadline fallback remains unexercised. Adaptive deadline buffering is measured directly.

The final rapid-seek request is 0.73 seconds. Expected PTS comes from the source's verified exact timestamp inventory using mpv's 5-ms accurate-seek tolerance: SDR selected 3/4, HLG selected 733/1000, and the variable-rate fixture selected 767/1000 after a deliberately missing frame. Preview timings observe renderer-current state, not physical scanout. Signed A/V values are raw mpv `avsync`: audio PTS minus video PTS plus configured audio delay/offset, opposite the shared engine's video-minus-audio convention. This value is cached when video is queued; repeated IPC samples of one displayed frame are not independent physical measurements. Absolute-offset acceptance remains unchanged. PCM pulses were not physically captured.

```sh
python3 scripts/generate-playback-fixtures.py --duration 30 --profile sdr --rate 24
python3 scripts/generate-playback-fixtures.py --duration 30 --profile hlg --rate 60
python3 scripts/generate-playback-fixtures.py --duration 30 --profile pq --rate 30
python3 scripts/test-mpv-policy.py assets/test-clips/playback/sdr-24-30s.mkv --model models/neural-rendering/NeuralRendering.dlssmodel --seconds 30 --report artifacts/mpv-policy-sdr24-broader.json
python3 scripts/test-mpv-policy.py assets/test-clips/playback/hlg-60-30s.mkv --model models/neural-rendering/NeuralRendering.dlssmodel --seconds 30 --report artifacts/mpv-policy-hlg60-broader.json
python3 scripts/test-mpv-policy.py assets/test-clips/playback/pq-30-vfr-30s.mkv --model models/neural-rendering/NeuralRendering.dlssmodel --seconds 30 --report artifacts/mpv-policy-pq-vfr-broader.json
```

Each report has matching `.engine.json`, `.configuration.json` and `.log` evidence. The recorded revisions are root `dad49c6df5c24765eb3e63b102c20349823048db`, mpv `efe0a783dac87021aabb7e6700faa00c2887a731` and MLX-DLSS `f2ce1772b98a0b862385fd71a1c45e137cdd4580`. Reports include the actual dirty source snapshot, source/manifest/model hashes, and SHA-256/size/mtime for the executable, libmpv, shared engine and MLX kernels; they verify those binaries did not change during each run. OSD dimensions were unavailable while paused, so actual native swapchain allocation in the mpv log supplies drawable evidence. Sampled process RSS maxima were 579,436,544, 585,334,784 and 591,626,240 bytes respectively. Detailed queue, allocator and completed-work timings remain in the engine reports; these observations are not hard memory limits.

The playback core now keeps both clocks paused until the completed frame's VO reconfiguration, subtitle dependencies and queue readiness have cleared. Previously it resumed at decoder completion, allowing later readiness checks to return early while audio advanced. Follow-up runs used the same conditions and retained the failed observations:

| Case | Wall interval | Completed fps | Steady A/V p95 / maximum absolute | Playback buffering | 20-ms target |
|---|---:|---:|---:|---:|---|
| HLG60 repeat | 30 s | 9.12 | 6.67 / 23.33 ms | 25.72 s | Failed, one frame at PTS 3.483 s |
| PQ variable-rate repeat | 30 s | 8.02 | 8.33 / 10 ms | 20.36 s | Met |
| PQ60 comparison | 30 s | 9.89 | 6.67 / 8 ms | 25.35 s | Met |
| HLG60 with boundary diagnostics | 25 s | 9.65 | 6.67 / 8.67 ms | 21.23 s | Met in this run |

All four runs passed exact preview/compare and bounded queue checks, observed no stale generations or decoder/VO drops, exited cleanly and kept their binary hashes unchanged. Reports are `artifacts/mpv-policy-{hlg60-clock-repeat,pq-vfr-clock-repeat,pq60-clock-repeat,hlg60-instrumented}.json` with matching engine/configuration/log files. Run the commands above with the corresponding source/report name; the diagnostic case uses `--seconds 25`, and PQ60 is generated with `--profile pq --rate 60`.

The instrumented HLG run recorded 238 buffering boundaries, a maximum 0.258-ms pause transition and 6.979-ms resume transition, without reproducing a greater-than-20-ms queue offset. It therefore does not explain or erase the earlier one-frame outlier. Clock acceptance, the remaining SDR/PQ/HLG rate combinations and physical presentation timing remain open.

### Native CLI window visibility

Standalone CLI windows honor `--focus-on=open`/`all` by applying key-window status together with front ordering after the activation request. Previously the key request preceded initial ordering; on the measured macOS desktop, the application became active while its window remained non-key and outside the active on-screen stack. The embedded application host owns its window ordering and returns before this CLI path. `--focus-on=never` and initially minimized windows retain their existing behavior. No always-on-top, all-Spaces or force-render option is enabled by the correction.

Opt-in `HDRPLAYER_MPV_VISIBILITY=1` writes `HDRPLAYER_MPV_WINDOW_STATE` JSON records directly to stderr. Records describe the actual presentation window: visibility, occlusion, minimization, key/main state, active Space, frame, native identity and drawable extent. Main-thread native notifications and 250-ms periodic observations are limited to 4,096 records. The [adapter comparison](adapter-comparison.md) checks observation coverage instead of assuming foreground activation establishes visibility.

[M3 window-order evidence](evidence/m3-mpv-cli-window-order.json) records the source SHA256, exact executable/library hashes, source revisions and changed-file hashes. Three paused PQ probes exited cleanly: the default focused window became key and occlusion-visible on the active Space and appeared in `CGWindowList`'s on-screen list; `focus-on=never` stayed inactive; an initially minimized window stayed minimized and invisible. The preceding binary's real playback window had valid bounds and alpha but was absent from that on-screen list. Metadata snapshots omit window titles. These bounded probes establish the correction on the measured desktop; the earlier ineligible four-run comparison remains unchanged.

Reproduce the focused condition with a built native CLI, retain stderr, and close the window after several periodic records:

```sh
HDRPLAYER_MPV_VISIBILITY=1 artifacts/mpv-build/mpv --no-config \
  --vo=gpu-next --gpu-api=vulkan --gpu-context=macvk --hwdec=videotoolbox \
  --pause=yes --keep-open=yes --mute=yes --geometry=960x496 --keepaspect-window=no \
  --osc=no --input-vo-keyboard=no --input-terminal=no \
  --focus-on=open assets/test-clips/playback/pq-30-60s.mkv \
  2> artifacts/mpv-window-focused.log
```

Repeat with `--focus-on=never`, then with `--window-minimized=yes`, retaining separate logs. Requested settings are controls; actual `isKey`, `appActive`, `onActiveSpace`, `occlusionVisible` and `isMiniaturized` observations determine the result. Other Space/display arrangements and sustained neural presentation remain separate checks.

### CoreAudio pause-clock tail

The later 160×96 adapter capture reproduced a 24-ms queue offset. Its trace showed CoreAudio's reported audio position advancing about 19 ms after the logical pause. The reset-based pull path retains a timed `end_time_ns` tail even while callbacks are stopped. Adaptive now uses that estimate and the last queued video frame's host deadline to request its hold earlier, with a 2-ms margin and a core timer in addition to the VO wakeup. Frame timestamps and mpv's A/V calculation are unchanged.

This behavior is an explicit CoreAudio driver opt-in. Unknown/non-running estimates, push outputs, hardware pause, continuous silence, untimed output and display-sync retain the ordinary deadline path. The estimate and pause use separate lock acquisitions, so another callback can occur between them; the margin is empirical. This does not guarantee physical audio drain or qualify another output device.

[M3 development evidence](evidence/m3-coreaudio-buffering.json) records the built-in speakers, muted CoreAudio, exact source and binary hashes, 960×496 drawable, and separate prototype/final-scope runs:

| Case | Processing | Wall interval | Steady scheduled A/V p95 / maximum absolute | Buffer episodes / duration |
|---|---:|---:|---:|---:|
| PQ30 | 160×96 | 30 s | 0 / 0 ms | 319 / 19.90 s |
| HLG60 | 32×24 | 30 s | 0 / 0 ms | 296 / 25.67 s |
| PQ variable-rate | 32×24 | 30 s | 0.333 / 3.333 ms | 276 / 18.96 s |
| HLG60, final CoreAudio-only scope | 32×24 | 25 s | 0 / 0 ms | 240 / 21.55 s |

All four runs passed exact preview/comparison, stayed at two pending frames, reported no decoder/VO drops or stale generations, exited cleanly and retained identical binary hashes throughout each capture. Eleven mpv unit checks and the native player DOM/teardown scenario also passed. The first three captures used the broader prototype; the final run verifies the guarded CoreAudio implementation. Earlier failures remain above.

Zero here is a scheduling result: mpv adds the future video deadline offset to the sampled audio-minus-video value. A frame queued early can therefore report zero by construction. These observations establish the reported scheduling target, not independent physical A/V accuracy. Source-rate neural Live playback, additional audio devices and physical presentation remain unqualified.

### Natural HDR10+ Adaptive timing

The policy harness keeps original file timestamps, rebased decoder timestamps and player coordinates separate. It validates the native packet offset against the exact first file frame, then brackets three paused decoder/player observations with completed-seek state over at least 100 ms. `--seek-target` remains a player-time request, defaulting to 0.73 seconds. `--file-seek-target` selects in the original file inventory. Both use mpv's existing 5-ms accurate-seek tolerance. Reports and sidecars must be new; `--require-visible` validates native observations over both warmed processing and playback-clock intervals.

[Natural M3 Adaptive evidence](evidence/m3-natural-hdr-adaptive.json) covers one 30.026-second run of the [pinned Apple HDR10+ source with AAC](apple-hdr-playback.md), starting at the previously inspected nonblack frame 1500. File PTS `1742501/24000` maps through the observed packet offset `-238944/24000` to decoder/player PTS `1503557/24000`; the separately validated decoder-to-player offset is zero. Real neural processing at 160×96 retains 1920×1080 linear float output, displayed through a 960×496 drawable. The M3 was on AC power with CoreAudio muted.

The run retained 195 completions, including 191 warmed samples at 6.51 FPS. The 927 clock observations covered 194 consecutive exact source frames and 8.050 seconds of source progress. Admission stayed at two pending frames, with no observed stale generations or decoder/VO drops. The exact source preview arrived in 77.9 ms, its enhanced pair in 1.092 seconds, and six paused comparisons preserved identity without another inference submission. Native visibility covered both full intervals, with no hidden/inactive observations and a maximum 252-ms observation gap.

MLX's configured free-cache limit was 268,435,456 bytes. The observed cache maximum was 288,542,364 bytes among warmed samples and 290,621,348 bytes including startup. The pinned allocator can recycle a whole buffer while the current cache is below the limit, then reclaim excess on the next allocation. The policy is therefore a soft limit; these snapshots do not establish a strict 256-MiB maximum or a process-memory ceiling.

All 866 steady scheduled A/V offsets were zero, meeting the existing 20-ms scheduling target; first/last-quarter median drift was also zero. Adaptive recorded 193 shared-buffer episodes totaling 22.398 seconds. Functional capture and the scheduling target are separate results. This bounded natural-content regression does not qualify source-rate Live, long-duration or physical A/V accuracy, HDR10+ display mapping, temporal image quality, or M5 performance. The first invocation failed before launching mpv because of an obsolete diagnostic provenance filename; its log is retained separately.

```sh
python3 scripts/test_mpv_policy_timing.py
python3 scripts/test-mpv-policy.py \
  artifacts/public-hdr-source-audit/apple-advanced-hdr10plus-aac.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 160 --height 96 --seconds 30 --file-seek-target 1742501/24000 \
  --require-visible --report artifacts/mpv-policy-apple-hdr10plus-new/report.json
```
