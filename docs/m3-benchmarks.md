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
