# M3 development measurements

All current measurements use Apple M3 with 16 GB. M5 Max measurements are scheduled after the hardware change; no M3 result is relabelled as target performance.

## Completed-work reference

Two sequential runs decoded 300 frames each from a continuous PQ source. Source/output size was 320×192, neural size 32×24, strength and colour strength 1, reference white 203 nits and maximum luminance gain 2. Each run excluded 30 startup frames. The GPU was reserved for these runs; power was battery at 73%. Output was offscreen RGBA16F, so presentation timing, audio drift and display energy are unavailable.

| Run | Completed / warmed | Completed FPS | Work p50 | Work p95 | Work p99 | Peak sampled RSS |
|---|---:|---:|---:|---:|---:|---:|
| A | 300 / 270 | 9.74 | 101.0 ms | 117.7 ms | 133.7 ms | 381 MB |
| B | 300 / 270 | 9.30 | 106.5 ms | 119.5 ms | 125.4 ms | 382 MB |

Sampled occupancy reached two slots and 4,376,192 retained frame bytes; the session admits at most three slots. The retained model payload was 291,576,650 bytes. MLX peak-active allocation was 617 MB and 597 MB respectively. Free cache observations briefly exceeded its 256-MiB policy, consistent with MLX reclaiming on subsequent allocations. These counters describe distinct resources and must not be summed as process RSS.

Ten startup-frame HDR sample locations were identical across both runs, including values up to 948.5 nits. The [numeric reference](evidence/m3-neural-reference.json) records locations, exact PTS, colour units, source/model hashes and settings. The [measurement summary](evidence/m3-engine-baseline.json) retains completed-stage distributions, unavailable metrics, binary identity and configuration. Full per-frame reports remain in `artifacts/m3-baseline/`.

This reference was collected from root revision `84290e5` while additive output-provenance and Prepared work was in progress. It validates repeatable instrumentation and bounded execution; it is not a clean-revision optimization comparison. The tiny neural shape is not a useful quality preset and cannot qualify source-rate Live playback.

## Reproduction

```sh
python3 scripts/generate-playback-fixtures.py --profile pq --rate 30 --duration 30
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i assets/test-clips/playback/pq-30-30s.mkv -map 0:v:0 -c:v copy -tag:v hvc1 -an \
  assets/test-clips/playback/pq-30-30s.mp4
source scripts/env.sh
swift build --product hdr-benchmark --jobs 2
bash scripts/prepare-frame-runtime.sh
.build/debug/hdr-benchmark --video assets/test-clips/playback/pq-30-30s.mp4 \
  --frames 300 --warmup 30 --width 32 --height 24 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --report artifacts/engine-repeat.json --reference artifacts/engine-reference.json \
  --revision "$(git rev-parse HEAD)" --power "$(pmset -g batt)"
```

Run sequentially and retain different report filenames. The `hvc1` sample entry is required by the evaluated AVFoundation path; FFmpeg's default `hev1` remux was rejected by that decoder. Source PTS and content hashes in reports describe the actual remux, including its millisecond-origin timestamp precision.

## Native playback evidence

The [mpv adapter](mpv-adapter.md) records the controlled Adaptive run, audio-clock offsets, original-first seek and same-frame comparison. The [Erika adapter](erika-adapter.md) records native drawable presentation, numerical HDR captures and overload behaviour. Their initial runs differed in display size, visibility and timing conditions, so they do not establish a playback-core winner. Longer 24/30/60-fps and VFR measurements use the continuous fixtures and remain part of playback qualification.
