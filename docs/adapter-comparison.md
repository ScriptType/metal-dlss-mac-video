# Playback-core comparison

mpv remains the provisional application core. Final selection requires the matched M5 results specified in issue #11. The current M3 capture provides development evidence and exposes remaining integration problems.

## M3 workload and capture

Four runs alternated mpv, Erika, mpv, Erika on Apple M3/16 GB with the same 60-second PQ source, model weights, 160×96 neural processing, 320×192 source/output geometry and 960×496 native drawable. Strength/colour strength were 1, reference white 203 nits and maximum gain 2. Both applications requested foreground activation and muted their own audio while retaining the device clock. Runs were sequential on battery at 58–57%; executable, shared-runtime and Metal-library hashes stayed unchanged. Source trees were development snapshots whose revisions and diff hashes are recorded.

mpv measured 30 seconds after its original-first seek and comparison sequence. Erika ran for 34 seconds with a scheduled seek at four seconds. The playback implementations differ under overload: mpv Adaptive pauses both clocks, while Erika rejects new admissions and repeats completed frames. The navigation harnesses and display mapping also differ. These runs compare completed work and expose integration limits; they are not identical Live sessions or a valid final presentation comparison.

| Adapter / run | Completed / warmed | Completed FPS | Work p95 | Sampled RSS peak | Observed overload |
|---|---:|---:|---:|---:|---|
| mpv / A | 283 / 279 | 9.41 | 124.8 ms | 562 MB | 20.92 s buffering; 281 episodes |
| Erika / A | 286 / 280 | 8.86 | 149.6 ms | 478 MB | 689 rejected admissions |
| mpv / B | 294 / 290 | 9.79 | 119.5 ms | 586 MB | 20.57 s buffering; 291 episodes |
| Erika / B | 216 / 210 | 6.73 | 178.0 ms | 472 MB | 727 rejected admissions |

mpv observed no decoder/VO drops or stale generations and at most two pending inputs. Its cached audio-minus-video clock samples had p95 absolute offsets of 7.67/8 ms and maximum offsets of 24/10.33 ms. Median quarter-to-quarter drift was +0.667/−0.667 ms. The first run failed the 20-ms maximum-offset target. Verbose boundaries show the audio position advancing during the enhancement hold; a cause and a validated correction remain required.

Erika reported 1,861/1,797 unpresented drawable callbacks. Only the first run had warmed drawable A/V samples, and only three of them: video-minus-audio estimates ranged from −338 to −233 ms. The second had none. Requested foreground activation does not establish physical visibility or valid presentation timing; these callbacks cannot be discarded to make a favourable comparison. Its admission drops and completed-frame drop markers are distinct from mpv's decoder/VO counters. Both adapters reported zero stale completions, but these results do not qualify Erika's synchronized playback or either adapter's physical HDR output.

The [machine-readable capture](evidence/m3-adapter-comparison.json) retains stage distributions, resource counters, timing limits and provenance. Full local reports/logs are under `artifacts/m3-adapter-comparison/`. Unavailable copy/readback/wait, energy, scanout and image-quality evidence stays explicit. No throughput difference is attributed solely to an adapter because overload policy, presentation callbacks and navigation differ.

## Reproduction

```sh
python3 scripts/generate-playback-fixtures.py --profile pq --rate 30 --duration 60
python3 scripts/compare-adapters.py \
  --source assets/test-clips/playback/pq-30-60s.mkv \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 160 --height 96 --seconds 30 --repeat 2 \
  --output artifacts/adapter-repeat
```

The command builds both adapters before measurement, alternates their runs, verifies actual reported dimensions and at least 60 warmed completions, and rejects binary changes between captures. `--skip-build` reuses existing binaries with their hashes retained. A successful capture does not imply presentation qualification or core selection. Use a new output directory and reserve the GPU for the complete sequence. Keep the same display, brightness and power source; record any changes before interpreting results.

The Erika example accepts `ERIKA_ADAPTER_DISPLAY_WIDTH/HEIGHT` as physical video pixels and adds its separate controls below that extent. `ERIKA_ADAPTER_MUTE=1` mutes application audio without disabling its clock. Its ordinary launch script records actual source/weights hashes and battery state. mpv's policy test accepts independent `--width/--height` neural dimensions while retaining its fixed measured drawable.

## Remaining decision evidence

Before final selection, resolve the mpv intermittent clock offset and Erika's incomplete drawable timing, then run the same retained engine configuration on M5. Qualify source-rate Live, tracks/subtitles/chapters/frame stepping, natural temporal content, HDR mapping and window/display transitions. Direct Metal libplacebo and a custom playback core remain conditional; the current development capture does not activate either replacement.
