# Shared frame engine

`FrameEngineShared` exports the C interface in `packages/CFrameEngine/include/frame_engine.h`.
Swift adapters can use `FrameSession` with the same processor and ownership rules.

## Frame boundary

Inputs are immutable, IOSurface-backed NV12/P010 decoder planes or RGBA16F linear BT.2020 RGB in absolute cd/m² (nits). Rational PTS and duration, source/stream/frame/generation, crop, rotation, pixel aspect and source colour interpretation travel with the pixels. HDR output is completed RGBA16F linear BT.2020 in nits. `source_colour` preserves source interpretation; `colour` describes transformed output. Source mastering and content-light maxima are not copied onto transformed pixels as if they remained valid.

`HDRPipelineProcessor` imports decoder planes, retains the HDR original, creates the model's bounded sRGB proxy, runs persistent neural processing, reconstructs HDR and packs half-float output. Reference white defaults to 203 nits. `maximum_luminance_ratio` bounds the reconstruction's luminance gain, independently of proxy bounds and display headroom. No display mapping occurs in this processor. The native surface maps the completed HDR output for its display once.

`model_path` names the extracted `.dlssmodel` directory. Null selects original bypass; `effect_strength=0` preserves the retained original before output packing. Processing dimensions configure the actual neural input independently of source/output dimensions. Changing source, temporal configuration or processing geometry requires a new generation or session as appropriate. Configuration strings are copied by `fe_session_create`; model loading and kernel construction occur on the worker.

## Ownership and scheduling

1. `fe_session_submit` validates the descriptor and returns accepted, full, cancelled, duplicate or failed without waiting for inference. On acceptance, the engine retains `pixel_buffer` and invokes `retain_owner` for any additional owner. Full/rejected input remains entirely caller-owned.
2. A supplied `ready_event` is a retained `MTLSharedEvent`. The producer must eventually signal `ready_value`, even if playback is cancelled. The worker waits through a GPU dependency. Submission never waits for that event.
3. Temporal inputs execute sequentially. Decode and presentation can run concurrently with the worker. The default capacity is three frame slots; accepted inputs, pending results and externally retained leases all count against admission. Frame storage reservations include input, HDR intermediates/output and proxy working storage. Model allocator/cache residency requires separate processor-level accounting and is not represented by the frame-storage counter.
4. `fe_session_poll` returns a GPU-complete output lease. The frame pointer and CVPixelBuffer remain valid until `fe_output_release`. If presentation encodes another GPU command, release the lease from that command's completion handler.
5. `fe_session_redraw` leases the most recent completed result without processing another temporal input. Missing a presentation deadline does not reset history.
6. Seek, source/stream replacement and input discontinuity call `fe_session_reset`. Its incremented generation invalidates queued and in-flight outputs. The adapter must compare the output generation against the session immediately before presentation; a lease already obtained before reset can remain physically valid while being obsolete for playback.
7. `fe_session_destroy` closes admission, cancels pending generations and returns immediately. In-flight GPU work and external leases retain their owners until actual completion/release. Before process exit or unloading the library, call `fe_session_close`, asynchronously poll `fe_session_is_idle`, then destroy and release all output leases. This keeps the MLX runtime alive while obsolete GPU work finishes. Do not call session functions concurrently with destruction or use the destroyed session pointer.

Within a generation, submissions must have strictly increasing PTS and unique successive frame identities. Repeated or earlier PTS returns duplicate. Source/stream replacement without reset returns failed. A failed processing input resets history before the next queued frame; it is distinct from a late, successfully processed frame. Errors after admission are available through `fe_session_error` and failure statistics.

## Process-wide model resources

Frame slots and bytes are separate from neural model residency. `HDRRuntimeResources` admits at most two retained neural processors by default, with a combined 1 GiB Safetensors payload and at most 147,456 processing pixels per processor (512×288). These conservative development limits bound model count, payload and workload shape. Model reservations live until the processor is destroyed after its GPU work; a full reservation fails explicitly. Zero-strength/original sessions do not construct or reserve a model. Preparation and playback share this policy.

The MLX reusable allocation cache is configured to 256 MiB before the first import or float allocation, including original-only sessions that never reserve a model. MLX reclaims excess free cache on its next allocation; this setting does not cap transient inference allocations or process RSS. Model file bytes are not an estimate of peak inference memory. Completed-frame reports retain actual MLX active/cache/peak-active and sampled RSS so larger workloads can be assessed independently of admission limits.

Before retaining neural processors, hosts can call `fe_runtime_configure` with a complete policy:

```json
{
  "maximumResidentModels": 2,
  "maximumResidentModelBytes": 1073741824,
  "maximumProcessingPixels": 147456,
  "mlxCacheBytes": 268435456
}
```

Reconfiguration is rejected while any model reservation remains alive. `fe_runtime_resources_json` reports current/peak admitted model count and payload bytes alongside the effective policy, using the same required-size/NUL convention as session reports. Raising limits requires workload measurements on the actual machine. The focused admission test checks aggregate payload/count limits, oversized workload rejection, retained ownership and capacity recovery.

## Validation

```sh
bash scripts/test-frame-api.sh
source scripts/env.sh
swift build --build-tests --jobs "$BUILD_JOBS"
bash scripts/prepare-frame-runtime.sh
swift test --skip-build --filter FrameSession
```

The plain C consumer releases its input reference immediately after submission, checks completed HDR samples and rational timing, requests a redraw, resets/destroys the session and checks that its output leases remain valid. Swift tests exercise bounded leases, cancellation during processing, duplicate submission, late-frame history and a real Metal readiness-event/copy round trip.

## Measurements

`FrameMeasurementRecorder` uses monotonic host seconds for submission, worker start, completed output and adapter presentation. CPU enqueue time, queue time and completed processing time are separate distributions. GPU stage intervals must come from completed GPU commands; synchronous MLX evaluation wall time is not labeled GPU time. The recorder excludes configured warm-up frames, reports source/processing/display dimensions separately and bounds retained samples to a configurable tail.

Adapters report actual presentation, video-PTS minus audio-clock offset, dropped frames, repeated presentation, observed copies/readbacks/waits, seek latency and measured warmed-interval energy through explicit hooks. Missing instrumentation is listed as unavailable. M3 reports are development evidence. Final M5 optimization and core selection require matched target-machine runs.

The C adapter configures measurements before its first submission with `fe_session_measurements_configure` and this JSON shape (replace all example values with the run's actual configuration):

```json
{
  "adapter": "mpv",
  "source": "hdr10-30.mp4",
  "sourceWidth": 320, "sourceHeight": 192,
  "processingWidth": 320, "processingHeight": 192,
  "displayWidth": 1920, "displayHeight": 1080,
  "sourceFPS": 30,
  "modelVersion": "weights-sha256-or-original",
  "implementationRevision": "git-revision",
  "settingsJSON": "{\"strength\":0}",
  "warmupFrames": 3,
  "displayConfiguration": "actual display and EDR policy",
  "powerConfiguration": "actual power and brightness settings"
}
```

`fe_session_record_presentation` takes monotonic host seconds and A/V offset seconds; NaN offset means unavailable. Report repeated redraws with the same generation/frame identity. `fe_session_record_drop`, `fe_session_record_transfers`, `fe_session_record_seek` and `fe_session_record_energy` provide the other measured boundaries. `fe_session_measurements_json` copies the report into caller storage and returns required bytes including NUL; retry if the required size exceeds capacity. GPU-stage names currently cover planar import and float packing; neural/proxy stages are completed wall intervals. MLX allocator values describe the process-wide MLX allocator, not exclusive per-session residency. Resident memory is sampled at completed frames and is not an exhaustive allocation high-water mark.

The offscreen development benchmark decodes directly into the shared session and checks accepted/completed counts and final rational PTS:

```sh
source scripts/env.sh
swift build --product hdr-benchmark --jobs "$BUILD_JOBS"
bash scripts/prepare-frame-runtime.sh
.build/debug/hdr-benchmark --video assets/test-clips/hdr10-30.mp4 \
  --frames 60 --warmup 3 --report artifacts/engine-pq.json --revision "$(git rev-parse HEAD)"
.build/debug/hdr-benchmark --video assets/test-clips/hdr10-30.mp4 \
  --frames 6 --warmup 3 --width 32 --height 24 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --report artifacts/engine-nr-tiny.json --revision "$(git rev-parse HEAD)"
```

These short commands validate instrumentation and model wiring. Sustained performance requires longer representative material, the intended processing dimensions, recorded display/power settings and the actual playback adapter. A tiny processing shape cannot establish a usable Live configuration.

The [M3 development reference](m3-benchmarks.md) records two 300-frame runs and an identical repeated numeric HDR capture. `--reference FILE` reads the first completed startup frame before the warmed interval; `--power DESCRIPTION` records actual power conditions. Benchmark errors drain pending GPU work before reporting failure.

For continuous clock and navigation checks, generate longer PCM-audio clips with five-second GOP targets, styled ASS, two audio tracks, chapters and exact source PTS manifests:

```sh
python3 scripts/generate-playback-fixtures.py --profile pq --rate 30 --duration 30
```

The command also creates a VFR variant by retaining four of every five source frames without resampling timestamps. Omitting profile/rate creates SDR/PQ/HLG at 24/30/60 fps. A 40-ms audio pulse and visible source-square pulse recur at each integer second. These synthetic fixtures support timing and controls checks; faces, natural grain and perceptual temporal acceptance require representative natural material.
