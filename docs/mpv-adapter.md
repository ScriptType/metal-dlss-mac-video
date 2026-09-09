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

`vf-command enhance policy adaptive` enables a shared buffering policy in mpv's playback core. When the displayed video's deadline expires before the next processed frame is available, mpv pauses both its audio output and video clock. The decoder/filter graph continues filling its bounded slots while controls remain responsive. Completed video resumes both clocks. Adaptive disables decoder/render frame dropping; it preserves source timestamps and HDR interpretation while effective playback throughput can be below the source rate. Processing dimensions and effect settings are explicit and independent of the presentation size.

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

`vf-command enhance prepare start` starts or resumes preparation; `cancel` stops future work while keeping committed ranges reusable. `enhancement-state.prepared` exposes `configurationState`, `jobState`, `completedSegments`, `totalSegments`, `processedFrames`, `reusedSegments`, `completedRanges`, `availableRanges`, `cacheHits`, `cacheMisses` and any `error`. The successful terminal job state is `complete`. `availableRanges` describes the current committed index; historical completion can include ranges already evicted by the disk budget. Acquisition still validates data and pins active readers.

Cache lookup uses exact source PTS and duration. A miss returns the HDR original through the same output lease and renderer path. The displayed frame's immutable `displayed-content-kind` distinguishes a cached enhanced frame from original fallback; the progress node's `lastOutput` describes background processing and must not label the currently displayed frame. `prepared-original` explicitly identifies a cached zero-strength reference. Prepared cache speed never qualifies neural Live mode.

The current float reference cache reads Float32 pixels from disk and packs a CPU-complete RGBA16F IOSurface before native hardware import. Measurements expose cache-read and packing wall time. This path preserves linear HDR precision; the separately evaluated HDR10 codec policy is not yet the production cache backend.

## Timing, cancellation and ownership

The FFmpeg decoder retains its original integer timestamp, duration and rational timebase in `mp_image`, alongside mpv's playback-clock timestamps. Copies preserve those fields without a floating-point round trip. The filter rejects missing rational timing or an upstream filter that changed the timeline without supplying corresponding rational timing. Supported SDR/PQ/HLG colour metadata is translated explicitly; Dolby Vision's reshaping path is not inferred from PQ.

The engine keeps three admitted slots. The filter retains at most three original frame references for matching completed outputs by frame identity. It applies backpressure through mpv's existing pins; it does not build an unbounded inference queue. A worker polls outstanding engine/Metal work at two-millisecond intervals and wakes the filter graph on completion. When no work is outstanding, it sleeps on a condition variable. Inference never runs in a render hook or on AppKit's thread.

Seeks and input geometry/colour discontinuities reset the engine generation and clear pending references. Output images carry a reference-counted atomic generation shared with the filter. `gpu-next` checks that generation at draw entry and immediately before rendering all contributing frames, including queued copies. A normal missed presentation deadline does not reset temporal state. mpv retains responsibility for audio playback, playback-clock scheduling, frame dropping and redraws.

The engine's completed buffer contains absolute-nit RGB. Libplacebo's linear working domain uses 1.0 = 203 nits, so the adapter performs one explicit Metal normalization pass into a bounded six-buffer RGBA16F pool. It preserves negative values and HDR headroom. A threadgroup reduction measures transformed peak luminance; reading that four-byte scalar after command completion supplies output peak metadata. Source-only ICC, Dolby Vision, film-grain and dynamic HDR metadata are cleared from transformed pixels.

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

The nine-second embedded HLG model smoke passed with the same processing dimensions and gain bound. It exercised exact seeks, pause/resume, resize, fullscreen and teardown. The surface reached RGBA16F with extended linear BT.2020 and EDR enabled; no renderer-owned window appeared, and removing the renderer left the host window alive. The report recorded ten dropped frames and a 1.172-second maximum absolute A/V offset including startup and lifecycle actions. This proves the embedding and shutdown path, while leaving sustained pacing unqualified. The machine-readable report is `artifacts/mpv-hdr-host-hlg-model.json`.

Sustained neural Live qualification, longer drift runs and physical presentation measurements remain acceptance work; absent metrics are reported as unavailable. Current development measurements target M3.

### Continuous M3 clock checks

The broader fixtures contain continuous PCM pulses, alternate audio, styled ASS subtitles, chapters and long GOPs. The first three Adaptive cases each used 30 seconds of wall playback after the seek/compare checks, with a 320×192 source, 32×24 neural processing, strength 1, reference white 203 nits, gain bound 2, a 960×496 native Vulkan swapchain and muted CoreAudio. They ran sequentially on battery power. All exited cleanly, retained exact source identity through six paused comparison switches, observed zero decoder/VO drops and stale generations, and sampled at most two pending frames.

| Source | Completed / warmed frames | Completed fps | Steady A/V median / p95 absolute / maximum absolute | Playback buffering | Original preview / enhanced pair |
|---|---:|---:|---:|---:|---:|
| SDR 24 fps | 281 / 277 | 9.41 | 4 / 8 / 9.33 ms | 18.66 s, 279 episodes | 83 / 927 ms |
| HLG 60 fps | 343 / 339 | 11.36 | 3 / 7.33 / 22 ms | 24.60 s, 341 episodes | 78 / 621 ms |
| PQ variable rate, nominal 30 fps | 268 / 264 | 8.89 | 2.67 / 9.33 / 20.33 ms | 19.20 s, 266 episodes | 89 / 1061 ms |

The HLG run exceeded the 20-ms target for one displayed frame at source PTS 4.583 seconds, observed in three consecutive samples. PQ variable-rate playback exceeded it at 8 seconds in four samples. Neither showed cumulative drift: the last-quarter median differed from the first by approximately −0.33 ms in every case. These are functional passes with two clock-target failures, so broader timing acceptance remains open. The next targeted checks are repeats of those cases and a PQ 60-fps comparison before expanding the remaining profile/rate combinations. No tested neural configuration qualified Live; actual qualified-Live deadline fallback remains unexercised. Adaptive deadline buffering is measured directly.

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
