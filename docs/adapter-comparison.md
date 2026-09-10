# Playback-core comparison

mpv remains the provisional application core. The latest matched two-adapter M3 comparison passes actual native visibility coverage for all four runs and its measured mpv scheduling-offset target. The captured Erika build lags audio under overload. Final selection requires the matched M5 and quality results specified in issue #11.

A subsequent [Erika transport candidate](erika-adapter.md#enhancement-hold-validation-on-m3) eliminates admission refusals and passes a bounded activation/audio clock check. Its measured window was occluded, and native lifecycle checks remain pending. That follow-up does not replace the matched visible comparison below.

## Visible M3 comparison

The [latest four-run capture](evidence/m3-adapter-comparison-visible.json) alternated mpv, Erika, mpv, Erika on Apple M3/16 GB. All four passed actual window visibility coverage, with maximum observation gaps of 0.251 seconds for mpv and 1.019 seconds for Erika. The complete warmed-work intervals and both mpv timed playback-clock intervals were covered. All application processes exited cleanly, and executable/shared-runtime/Metal-library hashes remained unchanged.

Each run used the same 60-second PQ/30-fps source with audio, model weights, 160×96 neural processing, 320×192 source/output geometry and 960×496 native drawable. Strength/colour strength were 1, reference white 203 nits and maximum gain 2. Runs were sequential on battery at 45–43%, with application-muted device clocks. Source revisions and build hashes are recorded separately: these are development binaries, with clean vendor source checkouts at capture. mpv measured 30 seconds after its seek/comparison sequence; Erika ran for 34 seconds with a seek at four seconds. Their overload policies, navigation sequences and display mapping still differ.

| Adapter / run | Completed / warmed | Completed FPS | Work p95 | Sampled RSS peak |
|---|---:|---:|---:|---:|
| mpv / A | 397 / 393 | 13.17 | 114.0 ms | 484 MB |
| Erika / A | 305 / 299 | 9.35 | 132.1 ms | 473 MB |
| mpv / B | 424 / 420 | 14.08 | 82.0 ms | 507 MB |
| Erika / B | 291 / 285 | 8.86 | 145.1 ms | 485 MB |

mpv's Adaptive policy buffered both clocks for 17.63/16.64 seconds, with no decoder/VO drops, no stale-generation observations and at most two pending inputs. Its cached audio-minus-video queue samples had maximum absolute offsets of 1.333/0.010 ms and p95 of 0 ms across 938/943 steady observations. Both met the measured 20-ms scheduling target. These samples do not measure physical audio/video scanout.

Erika recorded 1,959 positive and zero skipped drawable callbacks in A, and 1,965 positive plus one skipped callback in B. All 1,959/1,966 GPU commands completed successfully. Its 298/284 warmed drawable A/V samples had median video-minus-audio offsets of −290/−309 ms, with ranges −525…−206/−485…−198 ms. One warmed output per run lacks a usable current-generation presentation and remains in the report; one prior-generation callback in A was rejected by the existing generation check. The adapter rejected 674/693 new admissions while repeating completed frames. Native visibility and callback delivery are now established for these runs; synchronized overload behavior remains unqualified.

Shared retained-frame storage peaked at 5,777,024 bytes/two occupied slots for mpv and 8,665,536 bytes/three slots for Erika. Model/MLX allocator storage and sampled RSS are separate measurements. Copy/wait/readback totals, energy, physical HDR output and temporal image quality remain unavailable or separate qualification work. These results measure development configurations below the 30-fps source rate; they do not establish full-quality source-rate Live or a final M5 winner. Throughput changes relative to earlier captures cannot be attributed solely to visibility: builds, process warm-up and power/desktop conditions also differ.

## Earlier captures without visibility qualification

Four runs alternated mpv, Erika, mpv, Erika on Apple M3/16 GB with the same 60-second PQ source, model weights, 160×96 neural processing, 320×192 source/output geometry and 960×496 native drawable. Strength/colour strength were 1, reference white 203 nits and maximum gain 2. Both applications requested foreground activation and muted their own audio while retaining the device clock. Runs were sequential on battery at 58–57%; executable, shared-runtime and Metal-library hashes stayed unchanged. Source trees were development snapshots whose revisions and diff hashes are recorded.

mpv measured 30 seconds after its original-first seek and comparison sequence. Erika ran for 34 seconds with a scheduled seek at four seconds. The playback implementations differ under overload: mpv Adaptive pauses both clocks, while Erika rejects new admissions and repeats completed frames. The navigation harnesses and display mapping also differ. These runs compare completed work and expose integration limits; they are not identical Live sessions or a valid final presentation comparison.

| Adapter / run | Completed / warmed | Completed FPS | Work p95 | Sampled RSS peak | Observed overload |
|---|---:|---:|---:|---:|---|
| mpv / A | 283 / 279 | 9.41 | 124.8 ms | 562 MB | 20.92 s buffering; 281 episodes |
| Erika / A | 286 / 280 | 8.86 | 149.6 ms | 478 MB | 689 rejected admissions |
| mpv / B | 294 / 290 | 9.79 | 119.5 ms | 586 MB | 20.57 s buffering; 291 episodes |
| Erika / B | 216 / 210 | 6.73 | 178.0 ms | 472 MB | 727 rejected admissions |

mpv observed no decoder/VO drops or stale generations and at most two pending inputs. Its cached audio-minus-video clock samples had p95 absolute offsets of 7.67/8 ms and maximum offsets of 24/10.33 ms. Median quarter-to-quarter drift was +0.667/−0.667 ms. The first run failed the 20-ms maximum-offset target. Verbose boundaries show the audio position advancing during the enhancement hold; the subsequent [CoreAudio correction and controlled results](mpv-adapter.md#coreaudio-pause-clock-tail) are separate evidence and do not alter these captured failures.

Erika reported 1,861/1,797 zero-timestamp drawable callbacks. Adding the 92/85 positive callbacks accounts for all 1,953/1,882 HDR draws: callbacks were delivered, while most drawables were unpresented or skipped. Only six/three unique completed outputs had positive presentations; warm-up exclusion left three/no A/V samples. The first run's video-minus-audio estimates ranged from −338 to −233 ms. Requested foreground activation does not establish actual visibility or valid presentation timing; these callbacks cannot be discarded to make a favourable comparison. Its admission drops and completed-frame drop markers are distinct from mpv's decoder/VO counters. Both adapters reported zero stale completions, but these results do not qualify Erika's synchronized playback or either adapter's physical HDR output.

Subsequent [controlled Erika diagnostics](erika-adapter.md#controlled-presentation-diagnostics) established a reproducible cause: full window occlusion yielded 180 skipped presentations during three seconds while every GPU command succeeded; uncovering restored positive callbacks. A visible neural run had 49 warmed drawable A/V samples, but its median video lag was still 433 ms under overload. Background activation alone did not cause skipped presentations while the window remained occlusion-visible. The historical comparison did not record window state, so its particular cause remains unproven. Its original failures and raw reports remain retained.

The [machine-readable capture](evidence/m3-adapter-comparison.json) retains stage distributions, resource counters, timing limits and provenance. Full local reports/logs are under `artifacts/m3-adapter-comparison/`. Unavailable copy/readback/wait, energy, scanout and image-quality evidence stays explicit. No throughput difference is attributed solely to an adapter because overload policy, presentation callbacks and navigation differ.

## Earlier visibility check

The [earlier four-run visibility check](evidence/m3-adapter-comparison-visibility.json) completed with unchanged binaries and retained all samples. It remains ineligible as a matched presentation comparison: both mpv windows were absent from the visible native stack, while both Erika windows passed continuous native visibility coverage. Requested activation did not establish visibility. A separate metadata-only probe confirmed that the mpv diagnostic selected the actual playback window with valid in-display bounds. The [CLI ordering correction](mpv-adapter.md#native-cli-window-visibility) passed bounded probes and the latest visible comparison above; those results do not replace this failed capture.

| Adapter / run | Completed / warmed | Completed FPS | Native visibility eligible | Warmed drawable A/V samples |
|---|---:|---:|---|---:|
| mpv / A | 292 / 288 | 9.74 | No | Unavailable |
| Erika / A | 232 / 226 | 7.25 | Yes | 226 |
| mpv / B | 334 / 330 | 11.18 | No | Unavailable |
| Erika / B | 235 / 229 | 7.31 | Yes | 229 |

Erika recorded 1,927 positive and two zero timestamps in A, and 1,938 positive and three zero timestamps in B. All 1,929/1,941 GPU commands succeeded. One callback from the prior seek generation was identified and rejected by the existing generation check. Its median video-minus-audio estimates were −380/−382 ms, with ranges −695…−310/−671…−289 ms: visible playback still fails synchronized overload acceptance. mpv's cached queue A/V maxima were 15.851/0.006 ms with zero decoder/VO drops and at most two pending inputs; occlusion prevents treating those results as valid visible-playback comparison evidence. No throughput winner is inferred from these runs.

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

Both adapters now emit actual native window state to `.native.log`: Erika through `ERIKA_ADAPTER_DIAGNOSTICS=1`, mpv through `HDRPLAYER_MPV_VISIBILITY=1`. The comparison writes each `.visibility.json` and requires visible, occlusion-visible, unminimized state across the complete warmed-frame submission-to-completion interval. mpv additionally checks its exact timed playback-clock interval. Each interval requires an initial observation, unchanged window identity and no sampling gap longer than 1.5 seconds. Missing, truncated or obscured intervals are ineligible; native focus/activation and mpv's force-render request cannot substitute for actual occlusion state. Partial window visibility and physical scanout are not resolved by this gate.

The comparison completes and retains all four reports before returning status 2 if any visibility gate fails. `capturePassed` describes data capture; `visibilityEligible` describes native visibility coverage; `presentationComparisonQualified` remains false until synchronization and presentation acceptance are independently satisfied. No zero callback or frame sample is removed to obtain eligibility. The standalone Erika wrapper offers the same completed-work gate with `ERIKA_ADAPTER_REQUIRE_VISIBLE=1`.

The Erika example accepts `ERIKA_ADAPTER_DISPLAY_WIDTH/HEIGHT` as physical video pixels and adds its separate controls below that extent. `ERIKA_ADAPTER_MUTE=1` mutes application audio without disabling its clock. Its ordinary launch script records actual source/weights hashes and battery state. mpv's policy test accepts independent `--width/--height` neural dimensions while retaining its fixed measured drawable.

## Remaining decision evidence

Final selection requires matched M5 measurements with the same retained engine configuration and an explicit assessment of source-rate Live, tracks/subtitles/chapters/frame stepping, natural temporal content, HDR mapping and window/display transitions. An unresolved Erika integration failure is valid candidate-comparison evidence under issue #11; repairing it is not a prerequisite to continuing application work against provisional mpv. Direct Metal libplacebo and a custom playback core remain conditional; the current development capture does not activate either replacement.
