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

A four-buffer CoreVideo pool for the forward/backward RG16F destinations preserved the compared motion results but increased completed motion time on this M3 run. The candidate was removed, restoring the measured sources to `7af47d64b36b551ba091bedde0437c93ac92ff65`; that experiment left the production runtime unchanged. [Evidence](evidence/m3-flow-output-pool.json), [all 288 calls](evidence/m3-flow-output-pool.csv) and the [rejected candidate patch](evidence/m3-flow-output-pool-candidate.patch) retain the result for roadmap #8.

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

## Runtime HDR effect controls

The display codec now passes transfer and colour strength as two immutable Float32 inputs to the Metal resolve kernel. Changing either control no longer creates a distinct shader template specialization. Each lazy resolve owns its parameter array, and zero strength still returns the original object directly. White point, primaries, display-referred mode and maximum luminance ratio retain their existing specialization. [Evidence](evidence/m3-runtime-hdr-controls.json) and [all 192 calls](evidence/m3-runtime-hdr-controls.csv) record the M3 comparison.

Two persistent codecs processed the same synthetic 1920 × 1080 HDR inputs with 32 distinct positive control pairs. Four groups each ran eight settings once, then repeated them twice, alternating which implementation ran first. The timer includes native output construction and completed MLX evaluation; readback, hashing and comparison occur afterward. The frozen baseline reverses exactly to the codec source at MLX `7af47d64b36b551ba091bedde0437c93ac92ff65` after removing its test import and restoring four names.

| Completed resolve wall | Template controls | Runtime controls |
|---|---:|---:|
| Setting first-use mean, 32 calls | 58.187 ms | 9.685 ms |
| Setting first-use median | 55.498 ms | 9.222 ms |
| Setting first-use p95, nearest rank | 73.012 ms | 16.797 ms |
| Warmed mean, 64 calls | 8.722 ms | 8.304 ms |
| Warmed median | 8.286 ms | 7.674 ms |
| Warmed p95, nearest rank | 16.490 ms | 13.638 ms |

The main benefit is setting first-use in this process. Its initial candidate sample remains included; prior focused tests mean driver/disk caches cannot be described as cold. Warmed timings are much closer and subgroup results vary. Baseline code lives in the test module while production code lives in DLSSMLX, so these wall measurements do not isolate compiler or GPU execution costs. Readbacks and resource sampling also affect conditions outside the timer.

All 96 paired full-frame outputs match byte for byte, and every repeat matches its setting's first output. Sixteen additional small numerical controls pass both exact old/new parity and their CPU-reference bounds; eight verify exact zero-strength object bypass. Nine focused codec/native-HDR tests pass, including independent lazy parameter ownership, SDR/PQ/HLG imports and three real model frames. The original four portable codec tests retain their tolerances.

An initial new endpoint test failed a proposed 0.0005 CPU-reference bound at 0.00054931640625. A diagnostic replay found the same error in the old GPU implementation, with all sixteen old/new outputs bit-identical. The final endpoint test checks exact frozen-GPU parity on those unchanged inputs. The failed run, diagnostic output and executable hashes remain in the evidence; no tolerance was loosened to accept a changed result.

The benchmark process completed in 15.252 seconds with peak sampled process-tree RSS of 578,174,976 bytes and at least 14,708,879,360 free disk bytes. All frozen files and input frames remained unchanged. The benchmark used a 256-MiB MLX cache policy, then restored the prior policy. These are bounded observations of this short run.

The rebuilt integration passes the complete root check, including 40 Swift tests, and all 23 bundled-app controls/lifecycle checks. Two separate natural HDR controls reproduce source frames 1498 and 1528 at 1920 × 1080 with 512 × 288 neural processing. All eight new original/proxy/identity/enhanced views are finite and match both the prior fresh controls and their continuous-reference cut frames byte for byte. These sixteen comparisons preserve exact source timing, model and settings; two fresh frames do not establish continuous temporal quality. The published MLX change is [2fc9bf6](https://github.com/ScriptType/MLX-DLSS/commit/2fc9bf6dbf8b43f2db6683a7bd3afa3b554a4920).

To reproduce in this parent checkout, use a fresh release test process and a new output directory whose parent exists:

```sh
source scripts/env.sh
MLXDLSS_RUNTIME_HDR_CONTROLS_OUTPUT=/absolute/path/to/new-output \
swift test --package-path vendor/MLX-DLSS -c release --jobs 2 \
  --filter RuntimeHDRControlsBenchmarkTests
```

The test is opt-in and uses no model. Preserve the source, executed XCTest and metallib hashes with the report. The application still replaces its filter when effect settings change; this measurement does not establish complete slider latency, playback throughput, source-rate Live, temporal quality or M5 performance. Those acceptance gates remain open.

## Optical-flow stage attribution

Completed operation timings put VideoToolbox processing and MLX motion assessment ahead of input packing/resizing in this M3 workload. The production optical-flow algorithm is unchanged. A test-only copy adds clocks around its existing calls; removing the marked blocks and reversing two type names reproduces the production `NativeOpticalFlow.swift` bytes exactly. [Evidence](evidence/m3-flow-stage-attribution.json) and [all 288 calls](evidence/m3-flow-stage-attribution.csv) retain the measurements and comparisons.

The input is the same twelve 1920 × 1080 natural SDR proxy frames, 1496–1507, used for the rejected output-pool experiment. Two persistent estimators explicitly select VideoToolbox. Four alternating matched pairs each traverse the frames three times, retaining all calls and excluding each traversal's first three from warmed summaries: 108 warmed calls per arm. Repeated 1507 → 1496 boundaries remain explicit discontinuities.

| Warmed attributed operation | Mean | p95, nearest rank | Share of summed prepare wall |
|---|---:|---:|---:|
| Source-size half packing | 1.603 ms | 2.098 ms | 5.25% |
| Core Image resize | 1.337 ms | 1.804 ms | 4.38% |
| VideoToolbox session call | 14.779 ms | 19.011 ms | 48.39% |
| MLX motion assessment | 12.676 ms | 19.663 ms | 41.50% |
| Unattributed remainder | 0.146 ms | 0.232 ms | 0.48% |
| Complete prepare | 30.541 ms | 37.465 ms | 100% |

These are completed operation wall times, including scheduling, allocation and CPU work. The writer awaits its Metal completion handler; its separately reported GPU-command mean is 0.619 ms, nested within packing wall and excluded from the sum. Apple's [Core Image documentation from WWDC17, pages 89–91](https://devstreaming-cdn.apple.com/videos/wwdc/2017/510lf4jlju5s1/510/510_advances_in_core_image_filters_metal_vision_and_more.pdf?dl=1) states that the legacy CVPixelBuffer render API used here completes before returning. The VT interval includes destination allocation, parameter construction and callback resumption. Motion assessment includes flow import, confidence calculation, erosion, graph evaluation and scalar readback; it does not isolate erosion or any other kernel. Stage shares use summed times over the same 108 calls. Individual stage percentiles need not sum to the total percentile.

The production arm's warmed mean/median/p95 are 31.336/30.389/41.195 ms; the attributed arm's are 30.541/30.643/37.465 ms. Paired totals vary across groups. This difference is not an optimization result or an isolated measurement of clock overhead. The wrappers compile in different modules, and the attributed arm alone reads working pixels between calls. Hashing, retained comparison data, repeated traversals and resource sampling also influence operating conditions. The earlier 22.870-ms production mean came from a different harness/run; unchanged flow source does not support attributing the difference to the HDR control change.

All 144 paired signatures match, including one initial no-motion pair and 143 vector/confidence/scalar/reset results. All 24 direct motion-byte controls and twelve independent working-pixel controls match. The 144 attributed working-buffer hashes are stable for each source frame. Twelve tightly packed 960 × 540 RGBA16F references retain the actual logical pixel bytes; row padding is excluded, and all file writes occur after the 288 timed calls. The independent controls invoke the existing writer and resize primitives afterward; they do not expose the production estimator's private buffers. Three existing focused VT/automatic/Vision tests pass.

The measured process completes in 22.927 seconds with peak sampled process-tree RSS of 672,382,976 bytes and at least 14,105,321,472 free disk bytes. Sources, runtime and inputs remain unchanged, and the temporary 256-MiB MLX cache policy is restored to its prior value. These short-run observations do not establish sustained playback or a general memory ceiling.

Packing and resizing together account for 2.941 ms in the measured warmed mean. The next bounded investigation is motion assessment, with individual operation timing required before assigning its cost to erosion. Replacing the existing colour-managed resize or sharing command buffers remains an unmeasured candidate. No source-rate Live, temporal-quality, physical-display or M5 gate is closed by this attribution.

To reproduce, obtain the retained proxy inputs and reconstruct the exact input manifest described in the output-pool section, then run one fresh release test process with a new output directory:

```sh
source scripts/env.sh
MLXDLSS_FLOW_STAGE_INPUTS=/absolute/path/to/inputs.json \
MLXDLSS_FLOW_STAGE_ATTRIBUTION_OUTPUT=/absolute/path/to/new-output \
swift test --package-path vendor/MLX-DLSS -c release --jobs 2 \
  --filter NativeFlowStageAttributionTests
```

The test pins the actual executed XCTest, metallib, source and inputs. Existing root debug binaries are required as contamination controls. Preserve the raw reports, recorded operational bounds and hashes when interpreting a repeat.

## Original motion-confidence erosion

The existing 7 × 7 erosion operation takes enough time on the retained natural masks to justify a separate candidate comparison. [Evidence](evidence/m3-motion-erosion-cost.json) and [all 112 calls](evidence/m3-motion-erosion-cost.csv) record this measurement of the unchanged kernel. Production code remains unchanged.

One traversal of the twelve 1920 × 1080 proxy frames produces eleven actual pre-erosion masks; the initial frame has no motion. A source-identical test copy computes these masks from the same completed VideoToolbox buffers as production. All eleven complete vector/confidence outputs, scalar bits and reset decisions match production. The probe preserves production history ownership and retains each mask after the existing joint evaluation. It does not access production's private pre-erosion storage. All masks, confidence references and 22 logical RG16F flow payloads are retained with hashes.

After capture, the test releases the flow session and materializes the masks as independent MLX arrays. Every timed call constructs a fresh output from the original kernel and waits for completed evaluation. Readback, comparison and report writes follow the timer. Four measured passes follow one initial isolated pass and three warmup passes, alternating mask order. The initial isolated pass is already after kernel use during capture; it is not cold compilation.

| Input group | Measured calls | Mean | Median | p95, nearest rank |
|---|---:|---:|---:|---:|
| Eleven natural masks | 44 | 4.465 ms | 3.833 ms | 6.560 ms |
| All-positive control | 4 | 6.108 ms | 6.127 ms | 8.102 ms |
| Sparse-zero control | 4 | 6.803 ms | 7.555 ms | 7.829 ms |
| Dense-zero control | 4 | 1.296 ms | 1.258 ms | 1.494 ms |

All 112 outputs match their full-byte references. All fourteen mask/reference pairs also match an independent CPU Boolean-erosion calculation. Synthetic references exercise nonbinary confidence preservation and the radius-three effect of sparse/dense zeros. The erosion predicate is `input > 0`, distinct from the later `confidence > 0.5` reliable-fraction calculation. The two existing motion tests also pass in the newly built release XCTest.

The process completes in 10.168 seconds, with 21 resource samples, peak sampled process-tree RSS of 1,136,099,328 bytes and at least 12,732,391,424 free disk bytes. Before/after power readings both show battery power at 97%; the earlier flow-stage attribution ran on AC. All frozen pins remain unchanged, and the temporary 256-MiB MLX cache policy is restored. Different power, materialization, allocation and scheduling conditions prevent treating these isolated times as a fraction of, or subtraction from, the earlier bundled assessment measurement.

A separable Boolean erosion is the next candidate: it must preserve original centre confidence bits, prove a completed-work benefit in a paired comparison, and then pass full-motion/prepare parity and timing checks. This measurement retains no optimization and closes no playback, temporal, physical-display or M5 acceptance gate.

To reproduce with the same input manifest described above, use a new output directory:

```sh
source scripts/env.sh
MLXDLSS_EROSION_COST_INPUTS=/absolute/path/to/inputs.json \
MLXDLSS_EROSION_COST_OUTPUT=/absolute/path/to/new-output \
swift test --package-path vendor/MLX-DLSS -c release --jobs 2 \
  --filter NativeMotionErosionCostTests/testCurrentErosionOnActualConfidence
```

Preserve the executed XCTest, metallib, source and input pins, and record the power state and process limits with each repeat. Existing root debug binaries serve as contamination controls.
