# M3 development measurements

All current measurements use Apple M3 with 16 GB. M5 Max measurements follow the hardware change; no M3 result is labelled as target performance.

## Clean completed-work reference

Four sequential runs at root revision `dad49c6df5c24765eb3e63b102c20349823048db` decoded 300 frames each from a continuous PQ source. The benchmark was built in an isolated clean checkout with MLX-DLSS `f2ce1772b98a0b862385fd71a1c45e137cdd4580`. Every run excluded 30 startup frames. Source/output size was 320×192, strength and colour strength 1, reference white 203 nits and maximum luminance gain 2. Output was offscreen RGBA16F; presentation timing, audio drift and display energy are unavailable.

| Neural dimensions / run | Completed / warmed | Completed FPS | Work p50 | Work p95 | Work p99 | Peak sampled RSS |
|---|---:|---:|---:|---:|---:|---:|
| 32×24 / A | 300 / 270 | 11.14 | 88.8 ms | 102.6 ms | 107.4 ms | 352 MB |
| 32×24 / B | 300 / 270 | 10.55 | 93.0 ms | 109.2 ms | 125.8 ms | 382 MB |
| 160×96 / A | 300 / 270 | 10.40 | 95.8 ms | 107.3 ms | 114.5 ms | 382 MB |
| 160×96 / B | 300 / 270 | 10.04 | 99.7 ms | 108.2 ms | 112.8 ms | 383 MB |

The GPU was reserved for these runs. Power was battery, from 66% to 64%; CPU development builds continued during some runs. This is a reproducible development baseline, not a controlled performance comparison between processing shapes. Neither shape sustains the 30-fps source. The 32×24 shape validates instrumentation; 160×96 exercises an available application setting. Neither establishes perceptual quality or a source-rate Live preset.

Sampled occupancy reached two slots, with at most three admitted. Retained frame storage was 4,376,192 bytes at 32×24 and 5,777,024 bytes at 160×96. The model payload was 291,576,650 bytes. Maximum sampled MLX active allocation was approximately 305 MB, with peak-active counters of 557–610 MB. Free cache observations briefly exceeded its 256-MiB policy, consistent with MLX reclaiming on subsequent allocations. These distinct counters must not be summed as process RSS; completed-frame RSS samples do not measure every transient allocation.

All four reports contain 300 unique completed identities with ordered submission, worker-start and completion timestamps. Final PTS is exactly 159472/16000. Ten startup HDR sample locations were identical between repeated runs at each processing shape, including values above reference white. The [numeric references](evidence/m3-neural-clean-reference.json) retain locations, rational PTS, colour units, source/model hashes and settings. The [measurement summary](evidence/m3-engine-clean-baseline.json) retains stage distributions, unavailable metrics, clean revisions and executable/kernel hashes. Full per-frame reports are in `artifacts/m3-clean-baseline/` and `artifacts/m3-clean-160x96-baseline/`.

The earlier [in-progress reference](evidence/m3-engine-baseline.json) used root `84290e5` with uncommitted additive changes. Its 9.74/9.30-FPS results remain historical instrumentation evidence; differences from the clean run are not attributed to an optimization.

## Reproduction

```sh
python3 scripts/generate-playback-fixtures.py --profile pq --rate 30 --duration 30
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i assets/test-clips/playback/pq-30-30s.mkv -map 0:v:0 -c:v copy -tag:v hvc1 -an \
  assets/test-clips/playback/pq-30-30s.mp4
python3 scripts/benchmark-engine.py \
  --video assets/test-clips/playback/pq-30-30s.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --frames 300 --warmup 30 --width 160 --height 96 --repeat 2 \
  --output artifacts/engine-repeat-160x96
```

The wrapper builds and verifies clean engine sources, runs sequentially, records binary/source/model hashes and power state, checks completed counts and retains startup numeric references. Use a new output directory for each capture. `--project PATH` selects an isolated clean checkout; initialize its MLX-DLSS submodule and install/build the controls resources first. `--metallib PATH` can reuse a matching compiled MLX kernel library whose hash is recorded in provenance. The measured checkout was detached at `dad49c6`; benchmark wrapper code is retained in the publication commit.

The `hvc1` sample entry is required by the evaluated AVFoundation path; FFmpeg's default `hev1` remux was rejected. Source PTS and hashes describe the actual remux, including its millisecond-origin timestamp precision. Native mpv Prepared decoding has a separate source-timing contract.

## Native playback evidence

The [mpv adapter](mpv-adapter.md) records controlled Adaptive runs, audio-clock offsets, original-first seeks and same-frame comparison. Its longer HLG 60-fps and PQ variable-rate runs each exceeded the 20-ms target briefly, without progressive median drift. The [Erika adapter](erika-adapter.md) records native drawable presentation, numerical HDR captures and overload behaviour. Their initial runs differed in display size, visibility and timing conditions and do not establish a playback-core winner. Playback qualification and physical presentation remain separate from this offscreen baseline.

## Rejected VideoToolbox flow-output pool

A four-buffer CoreVideo pool for the forward/backward RG16F destinations preserved the compared motion results but increased completed motion time on this M3 run. The candidate was removed; the MLX fork remains at `7af47d64b36b551ba091bedde0437c93ac92ff65`, and the production runtime was unchanged. [Evidence](evidence/m3-flow-output-pool.json), [all 288 calls](evidence/m3-flow-output-pool.csv) and the [rejected candidate patch](evidence/m3-flow-output-pool-candidate.patch) retain the result for roadmap #8.

The actual `NativeOpticalFlow.prepare` comparison used twelve consecutive 1920 × 1080 SDR proxy frames, indices 1496–1507 from the [corrected full-resolution HDR reference](temporal-reference.md#regression-with-bounded-resized-model-input). Two persistent estimators explicitly selected VideoToolbox. Four alternating matched pairs each traversed the inputs three times, excluding the first three calls of every traversal: 288 total calls, 216 warmed, 108 warmed per strategy. The source-size half conversion, CI resize to 960 × 540, 240 × 135 flow extent and motion calculations were unchanged. Repeated 1507 → 1496 boundaries were recorded as artificial discontinuities.

| Completed prepare wall | Fresh destinations | Pooled destinations |
|---|---:|---:|
| Warmed mean | 22.870 ms | 24.243 ms |
| Warmed median | 22.294 ms | 23.268 ms |
| Warmed p95, nearest rank | 27.013 ms | 29.912 ms |
| Warmed sum, 108 calls | 2.469942 s | 2.618296 s |

Warmed total time increased 6.01%. Pooled sums and p95 were higher in all four pairs; medians were higher in three. The 99.039-ms pooled outlier remains included. Individual traversal sums were mixed. This short shared-process measurement does not establish why pooling was slower or predict other machines or workloads.

All 144 matched signatures agreed, including one initial no-motion result and 143 vector/confidence hashes with scalar bit patterns and reset state. All 24 direct full-array byte controls agreed. Eleven focused release tests passed, covering retained-buffer capacity/reuse, partial-pair failure cleanup, lazy MLX ownership through pool destruction, retained-motion immutability and existing VT/automatic/Vision behavior. The actual benchmark test passed separately. Production code was restored only after the independent frozen-source audit; applying the archived patch to the base reproduces all three candidate source files exactly.

An earlier CPU-only allocation probe measured a flow-pair median of 44.083 µs with fresh allocations and 6.333 µs with pooling. Its six balanced rounds contained 4,608 measured iterations and 576 warmups across three cases. It performed no pixel writes, CI rendering, VT processing or MLX work, and used default pool age-out; the actual candidate disabled age-out. These allocation-call savings did not translate to faster completed motion. Recycled IOSurface IDs in fresh allocations also prevent interpreting unique ID counts as persistent backing-allocation counts.

The actual benchmark process took 18.961 seconds and reached 876,527,616 bytes of sampled process-tree RSS; the peak was its final sampled row after all calls were published. All 37 resource samples remain in the evidence. MLX peak-active allocation reached 396,491,024 bytes in the shared process, with a 256-MiB cache policy restored to its prior value afterward. RSS, MLX counters and allocation measurements have different scopes. Array readback and hashing were outside the prepare timer but affected process resources and operating conditions. No model or player ran; no source-rate Live, full-model quality or M5 acceptance follows from this experiment.

To reproduce the rejected candidate, use an experimental checkout at the recorded base and apply the patch inside `vendor/MLX-DLSS`. The evidence's `design.inputManifest` contains exact proxy paths, hashes and rational timestamps; its payloads come from the retained corrected reference and are local artifacts. Reconstruct the byte-pinned manifest with Python `json.dumps(object, indent=2) + "\n"` using the default ASCII escaping; verify SHA256 `3c376d69b898a7fa0ee2474e233438c9071dbe3d63b3cece57d9b8e1bfa68181`. Build and run the opt-in test with new output paths:

```sh
source scripts/env.sh
git -C vendor/MLX-DLSS apply ../../docs/evidence/m3-flow-output-pool-candidate.patch
MLXDLSS_FLOW_POOL_INPUTS=/absolute/path/to/inputs.json \
MLXDLSS_FLOW_POOL_BENCH_OUTPUT=/absolute/path/to/new-output \
swift test --package-path vendor/MLX-DLSS -c release \
  --filter NativeFlowOutputPoolBenchmarkTests/testMatchedFullResolutionVideoToolboxPoolBenchmark
```

The test also pins the root debug benchmark/shared library/metallib as contamination controls; those files must be present, but the executed code is the release XCTest and its bundled metallib. Preserve hashes and run under the recorded process/resource limits for a comparable capture. Do not adopt the patch without new evidence of benefit.
