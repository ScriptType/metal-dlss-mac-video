# Consecutive neural reference capture

The diagnostic `hdr-benchmark --reference-sequence` mode processes consecutive source frames through one persistent `NativeHDRProcessor`. Each result supplies original, neural proxy, identity reconstruction and enhanced views from the same source frame and exact timestamp. This mode writes full Float32 references before output packing or display mapping. It does not measure playback throughput or establish temporal quality.

## Input contract

Provide a schema 1 JSON manifest alongside raw input files:

```json
{
  "schemaVersion": 1,
  "width": 320,
  "height": 134,
  "layout": "RGB float32 little-endian top-to-bottom",
  "primaries": "BT.2020",
  "transfer": "linear",
  "units": "cd/m2",
  "provenance": {
    "description": "Source hashes, publisher interpretation, explicit transforms and assumptions"
  },
  "frames": [
    {
      "sourceFrameIndex": 10000,
      "path": "frame-10000.rgb32f",
      "sha256": "64 hexadecimal digits",
      "pts": { "value": 0, "timescale": 2997 },
      "duration": { "value": 125, "timescale": 2997 }
    }
  ]
}
```

Each payload contains tightly packed RGB Float32 values with no alpha, stride padding, colour conversion or normalized-white scaling. Finite negative and greater-than-10,000-nit components remain intact. Relative paths must resolve to regular files inside the manifest directory, including after symlink resolution. Preflight checks every file's exact size, hash and finite components before allocating a model. A second check immediately before processing detects changed payloads or paths. The captured original must match the input payload byte for byte.

Source frame indices and rational PTS must increase strictly; durations must be positive. Explicit timing gaps or overlaps are preserved. The manifest must contain 1–120 frames, each at most 2,073,600 pixels. The intended natural-scene inspection contains 48–120 consecutive frames. The first supplied frame starts with cold history; no frames are silently added as preroll or removed as warmup.

`provenance` is preserved verbatim, and an exact copy and hash of the full input manifest retain any additional per-frame source fields. An image sequence's assigned derivative timeline must be distinguished from publisher-established timing. Likewise, a selected interpretation of ambiguous colour metadata remains an assumption in the capture; this tool does not certify it. Untagged video and EXR files are not decoded by this mode.

## Capture

```sh
source scripts/env.sh
swift build --product hdr-benchmark -j 2
.build/debug/hdr-benchmark --reference-sequence-validate INPUT/manifest.json
.build/debug/hdr-benchmark \
  --reference-sequence INPUT/manifest.json \
  --output artifacts/temporal-reference \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 160 --height 96
```

Validation is CPU-only. The capture runs inference and must use a reserved GPU window when other measurements are active. The output directory must be new. Run from the repository root to record source revisions and file hashes; the report marks unavailable provenance instead of inventing it.

Optional settings are `--frames`, `--strength`, `--colour-strength`, `--maximum-luminance-ratio`, `--reference-white`, `--motion` and `--maximum-output-bytes`. Defaults are all supplied frames, strength 1, colour strength 1, ratio 2, white 203 nits, automatic optical flow and a 2 GiB output allowance. An explicit `--maximum-output-bytes` may raise that allowance to at most 6 GiB, including the 4 MiB metadata reserve. The CPU-only `--reference-sequence-validate` command accepts the same option. Motion also accepts `videotoolbox`, `vision` and `zero`; `zero` disables optical flow and must not be represented as an automatic-flow result. Processing dimensions default to 160 × 96 and may contain at most 512 × 288 pixels. Temporal mode, float16 model precision and scene-cut threshold 0.3 remain fixed.

Four Float32 RGB views require `frames × width × height × 48` bytes. Preflight reserves another 4 MiB for bounded manifests and frame metadata, within the selected allowance (2 GiB by default, at most 6 GiB by explicit opt-in). The capture processes one frame at a time and writes one view at a time; the model and its temporal state persist. It configures MLX's soft free-cache policy to 256 MiB. Whole-buffer releases can exceed that value until a later allocation reclaims cached buffers; it is neither an instantaneous cache ceiling nor a hard process-memory limit.

Each frame directory is staged before atomic publication. The run manifest records only published frames and remains `complete: false` until all selected frames finish and the input manifest/model hashes are rechecked. A failed or interrupted run is preserved as incomplete; it is not resumable because reconstructing temporal state would require replay. Use a new output directory for a repeat.

The report records source identity, exact PTS/duration, frame index, generation, settings, model files, implementation/binary hashes, Metal device, completed stage wall times, allocation snapshots and full-view hashes/statistics. All four views are generated from one result, without a second neural submission. `historyReset` combines input/geometry discontinuities and detected cuts. `knownInputDiscontinuities` identifies cold start, skipped source indices and PTS gaps exceeding the processor's existing threshold; it does not claim a specific internal reset reason. The public result does not expose cut scores or the selected automatic optical-flow backend.

New captures record `modelInputRange: bounded-sRGB-after-resample`: native HDR processing bounds the resized model input before feature generation and postprocessing. The exported proxy remains the source-size encoded view. Its range alone does not prove the range of a resized model input. Earlier manifests retain their original runtime provenance and are not relabeled with the new policy.

## CPU review artifacts

```sh
uv run --frozen python scripts/review-reference-sequence.py \
  artifacts/temporal-reference/manifest.json \
  --output artifacts/temporal-reference-review
open artifacts/temporal-reference-review/index.html
```

The reviewer accepts `--maximum-input-bytes` to opt into at most 6 GiB of raw input; its default remains 2 GiB. Generated review files retain a separate 2 GiB limit. A capture manifest cannot raise either caller limit.

The review script first requires a complete capture and validates its input-manifest copy, paired exact timing, original identity and every payload. It creates one four-panel PNG per frame, `review.json`, and a local frame-step/play viewer. Publication occurs only after all outputs finish. The review directory must be new; raw captures are never rewritten.

Original, identity and enhanced previews share a fixed mapping: clamp negative source components for review, divide by the captured reference white, multiply by the recorded BT.2020-to-BT.709 matrix, roll luminance above 0.75 toward 1 with the existing codec's exponential knee, clip the resulting gamut to 0–1, encode sRGB and round to 8-bit PNG with an embedded sRGB ICC profile. Clipping and quantization statistics are recorded separately. No per-frame exposure or histogram adaptation occurs. The proxy is already bounded, encoded sRGB; it receives only PNG quantization, avoiding a second transfer function.

The full raw references preserve values lost in these SDR inspection images. Numeric identity-versus-original and enhanced residual errors remain in nits. Consecutive residual differences compare fixed pixel coordinates and can be dominated by motion or cuts; they are observations, not quality scores. The viewer retains exact rational labels, pairs labels with completed image loads and reports frames skipped by its browser scheduler. Browser playback, mapped previews and allocator samples do not establish physical HDR accuracy, presentation cadence or A/V synchronization.

## CPU checks

```sh
.build/debug/hdr-benchmark --reference-sequence-self-test
uv run --frozen python scripts/review-reference-sequence.py --self-test
```

These checks cover raw-value preservation, malformed timing, corruption, length mismatch, directory/symlink escape, nonfinite data, fixed mapping, proxy transfer handling and complete/incomplete review publication. They use synthetic CPU data and do not substitute for a real neural sequence capture.

## M3 natural-sequence observation

The [48-frame capture](evidence/m3-temporal-reference.json) processed Cosmos Laundromat source frames 10000–10047 at 320 × 134, using 160 × 96 neural processing and the declared 2997/125 derivative frame rate. All 48 originals matched the input Float32 bytes exactly, and every view remained finite. Identity reconstruction differed by at most 0.0009765625 nit. The process completed in 10.225 seconds, including diagnostic work; this is not a playback benchmark.

The visible cut from the dial close-up to the character shot at source frame 10002 coincided with `historyReset: true`. Resets occurred at ordinals 0 and 2. The public result does not identify cut scores or per-pixel history acceptance, so this observation alone does not establish acceptable temporal behaviour. The deliberately small processing dimensions also soften visible detail. Review files are retained at `artifacts/cosmos-reference-review-final/index.html`; raw paired data is in `artifacts/cosmos-reference-capture`.

The input retains its initial D65-assumption label, extended PQ outside its nominal domain and float BOX downsampling. A separate [publisher metadata match](open-content-reference.md#publisher-metadata-match) now identifies D65 for the source files without rewriting historical manifests. Finite negatives and values above 10,000 nits remain in the references. Calibrated colour, physical output and broad natural-scene quality remain unqualified. A later CPU-only diagnostic fix preserves rational subtraction for very large PTS values; the evidence retains the original capture hashes and separately records the final 10 Swift and 15 Python CPU checks.

The [320 × 192 follow-up](evidence/m3-temporal-reference-320x192.json) uses the same 48 source frames, exact timing and model. It completed in 11.656 seconds with unchanged binaries and inputs. A separate process started directly on source frame 10002 at the same settings: all four full RGB32F views were byte-identical to that frame in the continuous run. This verifies the observed cut's result against fresh history for this configuration; it does not establish all subsequent flow-state behaviour or other cuts. Identity reconstruction again differed from original by at most 0.0009765625 nit. The larger processing dimensions alone do not establish Live qualification. Review files are at `artifacts/cosmos-reference-review-320x192/index.html`.

## Apple natural HDR reference

The [Apple sequence observation](evidence/m3-apple-temporal-reference.json) covers source frames 1488–1543 from the pinned HDR10+ trailer in [the source catalog](evidence/apple-natural-hdr-source.json). The 56-frame window includes two cuts, faces, hand/cup movement, a liquid splash and a side-lit spoon shot. All eight inspection-prelude frames remain in the capture; the review interval is 1496–1543. First and last original file PTS are 1730489/24000 and 1785544/24000, with duration 1001/24000 for every frame. No player rebasing or forced scene resets are applied.

Prepare the input using the existing pinned source file and decoded metadata inventory. The default converter is `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`; use `--ffmpeg PATH` for another build that provides the `zscale` filter:

```sh
uv run --frozen python scripts/test_apple_hdr_reference.py
uv run --frozen python scripts/prepare-apple-hdr-reference.py \
  --output artifacts/apple-temporal-reference-input-new
.build/debug/hdr-benchmark --reference-sequence-validate \
  artifacts/apple-temporal-reference-input-new/manifest.json
.build/debug/hdr-benchmark \
  --reference-sequence artifacts/apple-temporal-reference-input-new/manifest.json \
  --output artifacts/apple-temporal-reference-capture-new \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 320 --height 192 --strength 1 --colour-strength 1 \
  --maximum-luminance-ratio 2 --reference-white 203 --motion automatic
uv run --frozen python scripts/review-reference-sequence.py \
  artifacts/apple-temporal-reference-capture-new/manifest.json \
  --output artifacts/apple-temporal-reference-review-new
```

The preparer performs software HEVC decoding and full 1920 × 1080 PQ linearization. By default it then applies a Float64-accumulated 2 × 2 linear BOX reduction to 960 × 540. `--full-resolution` instead retains decoded Float32 RGB at 1920 × 1080, with the same 56 frames, exact timing and eight-frame inspection prelude. Geometry and reduction policy are recorded explicitly in the manifest. Its explicit zscale settings use limited-range BT.2020 NCL, top-left bilinear chroma, `npl=1` and `agamma=false`; planar G,B,R output is reordered into RGB absolute nits. The reference has no white-point scaling, gamut conversion or post-linearization clamp. Actual pre-conversion `showinfo` timestamps and durations must match the pinned inventory exactly. The original compressed source and unchanged raw ffprobe JSON remain authoritative provenance: parsed per-frame metadata is a projection because ffprobe emits repeated JSON keys. HDR10+ display tone mapping is neither applied nor attached to the numerical derivative.

A full-resolution input needs 1,393,459,200 raw bytes; its four captured views need another 5,573,836,800 bytes plus metadata. Use the explicit larger allowance for both capture preflight and review. Neural processing dimensions remain independently set to 320 × 192 in this example:

```sh
uv run --frozen python scripts/prepare-apple-hdr-reference.py \
  --full-resolution --output artifacts/apple-temporal-full-input-new
.build/debug/hdr-benchmark --reference-sequence-validate \
  artifacts/apple-temporal-full-input-new/manifest.json --maximum-output-bytes 6442450944
.build/debug/hdr-benchmark \
  --reference-sequence artifacts/apple-temporal-full-input-new/manifest.json \
  --output artifacts/apple-temporal-full-capture-new \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 320 --height 192 --strength 1 --colour-strength 1 \
  --maximum-luminance-ratio 2 --reference-white 203 --motion automatic \
  --maximum-output-bytes 6442450944
uv run --frozen python scripts/review-reference-sequence.py \
  artifacts/apple-temporal-full-capture-new/manifest.json \
  --output artifacts/apple-temporal-full-review-new --maximum-input-bytes 6442450944
```

Mandatory synthetic conversion controls check transfer normalization, channel order and chroma treatment against an independent analytic reference, with absolute tolerance 0.0001 nit plus relative tolerance 0.00005. An earlier stricter extended-domain check failed by 0.7875 nit at an expected 19423.49 nits; its report and source are retained. This does not establish a uniform error below 0.001 nit. The actual source window has no negative or above-10000-nit linear components; its maximum falls from 1635.3121 nits before BOX reduction to 999.1243 after it. The measured preparation also used `--conversion-audit artifacts/apple-temporal-conversion-audit/report.json`, pinning the separately verified 19-control audit and matching FFmpeg binary. That optional local report is not required for other runs. Thirteen CPU regression cases cover input/metadata/timing errors, numerical layout, output preservation and a stalled decoder terminated by the watchdog. Existing paths and dangling output symlinks are refused; failed conversion leaves an incomplete preparation report. The decoder deadline is 300 seconds.

The M3 continuous capture completed all 56 frames with unchanged inputs, model and runtime binaries. All 224 raw views are finite, every original is byte-identical to its input, and maximum identity error is 0.00006103515625 nit. Eleven small negative enhanced components remain in the raw output (minimum −0.000312234 nit). Automatic history resets occurred only at cold source frame 1488 and the two observed cuts, 1498 and 1528. Independent one-frame processes at both cuts produced byte-identical original, proxy, identity and enhanced views: all eight comparisons had zero difference. These checks establish exact cut-frame equivalence for this configuration. They do not establish all subsequent motion-history behaviour. The diagnostic process took 77.543 seconds including preflight, readback and file output; this is not playback throughput. The input requires 348,364,800 bytes and the four raw views 1,393,459,200 bytes, plus metadata and reviews.

Review files are at `artifacts/apple-temporal-reference-review-1/index.html`. Independent inspection of 13 named four-panel stills found no obvious previous-shot image or fixed tiling seam in those samples, while enhancement visibly changed face brightness and colour. Saturated title highlights clip in the fixed SDR review mapping. An exploratory wall region in the cup shot had maximum adjacent mean-luminance changes of 0.2635 nit in original and 0.9854 nit in enhanced; the corresponding residual change reached 0.9264 nit. The retained region measurements have no motion compensation or perceptual threshold. Neither aesthetic improvement nor flicker-free playback is established. The full-resolution follow-up below extends capture coverage; temporal quality, broader motion/corpus coverage, physical HDR and source-rate Live qualification remain open.

## Full-resolution Apple reference

The [full-resolution capture](evidence/m3-apple-temporal-full.json) retains the same 56 frames at 1920 × 1080, with **320 × 192 neural processing**. All reconstructed planar G,B,R hashes match the earlier decoded frames, and applying the earlier Float64 BOX reduction to every new input reproduces all 56 historical 960 × 540 inputs byte for byte. Source indices, original file PTS, durations, metadata projection and the eight-frame inspection prelude also match. The original peak of 1635.3121 nits remains in the full-resolution reference.

All 224 raw views pass hash and finite-value checks, and every captured original matches its input exactly. Maximum identity component error is 0.0001220703125 nit, at an original green component of 1635.3121 nits; aggregate component RMS error is 0.000002274 nit. The enhanced references retain 99 small negative components, with minimum −0.000408964 nit. Resets occur only at 1488, 1498 and 1528. Two separate fresh processes at the latter cuts reproduce all eight continuous views byte for byte, including enhanced output.

The complete diagnostic process takes 302.161 seconds, including preflight, inference, readback and file output. Peak sampled RSS is 577,323,008 bytes. The maximum sampled MLX free cache is 291,264,158 bytes under its soft 256 MiB policy; whole-buffer releases may exceed that policy. These observations do not measure source-rate playback. Default 2 GiB preflight and review allowances refuse this workload; both explicit 6 GiB controls pass. The reviewer still caps generated output separately at 2 GiB. Thirty Swift CPU checks, 19 CLI allowance controls, 31 reviewer checks and 13 preparation checks pass for the tooling.

All 56 four-panel PNGs are retained at `artifacts/apple-temporal-full-review-1/index.html`. Inspection of 12 named SDR stills finds no obvious previous-shot image at either cut or fixed tiling seam at the displayed overview scale. Enhanced face brightness, colour and softness differ visibly. Three independently inspected stills agree with these limited observations; neither review establishes fine-detail quality across all frames or physical HDR accuracy.

The same unaligned cup-wall rectangle, scaled to `[40, 80, 360, 720]`, retains all 30 frames. Original means agree with the historical half-resolution means within 0.0000000165 nit. Maximum adjacent mean-luminance changes are 0.2635 nit in original and 1.2491 nits in enhanced. The largest enhancement-residual change is 1.1295 nits at 1503→1504; the historical half-resolution series reaches 0.9264 nit at 1526→1527. [Scalar measurements (CSV)](evidence/m3-apple-temporal-full.csv) and [trajectory plot (PDF)](evidence/m3-apple-temporal-full.pdf) preserve both complete series. Proxy encoding is nonlinear and precedes neural resampling and motion estimation, so BOX-equivalent originals do not require equal enhanced results. Benchmark revisions also differ. This comparison isolates neither a geometry effect nor a model defect, and uses no new registration or perceptual threshold.

## Regression with bounded resized model input

The [corrected full-resolution repeat](evidence/m3-apple-temporal-bounded-input.json) processes the same 56 inputs with the native HDR [input-range correction](evidence/m3-native-hdr-model-input.json). Source/reference size remains 1920 × 1080 and neural processing remains 320 × 192. All 224 new views pass integrity and finite checks. Every original, proxy and identity view matches the previous full-resolution capture byte for byte: 168 direct comparisons pass. Maximum identity error remains 0.0001220703125 nit. All enhanced frames differ; the largest component change is 67.2242 nits. The raw enhanced output retains 28 small negative components, with minimum −0.000469545 nit. History resets remain 1488, 1498 and 1528; both fresh cut controls reproduce all eight continuous views exactly.

The fixed 30-frame wall series still varies after the range correction. Maximum adjacent E−O change increases from 1.1295 to 1.6552 nits at 1503→1504, and RMS adjacent change increases from 0.5299 to 0.6837 nit. Mean E−O falls from 0.9326 to 0.5720 nit. [Complete scalar series (CSV)](evidence/m3-apple-temporal-bounded-input.csv) and [trajectory plot (PDF)](evidence/m3-apple-temporal-bounded-input.pdf) retain both runs. Independent raw replay reproduces the largest pair exactly. This enforces the declared input contract without eliminating the measured temporal variation or establishing perceptual improvement. No new registration or quality threshold is applied.

The diagnostic process completes in 296.686 seconds. Its sampled RSS peaks briefly at 1,012,121,600 bytes, compared with 577,323,008 bytes previously, then falls to 75,726,848 bytes by 49.851 seconds. From 120 seconds onward it stays below 214 MiB. Retained MLX active values match at every frame boundary: 402,622,764 bytes first, then 402,884,904 bytes. The higher startup-region peak remains unexplained; RSS and MLX counters use different accounting and cannot identify its cause. These samples show neither a hard memory ceiling nor a demonstrated progressive leak. All raw resource samples remain in the pinned audit.

Review files are at `artifacts/apple-temporal-bounded-input-review-1/index.html`. All 56 image hashes pass; inspection of three named SDR overviews at 1498, 1504 and 1528 retains visible brightness/colour/softness changes without obvious previous-shot carryover. This still-image review does not qualify physical HDR, fine detail across all frames, or flicker-free playback.

## Wall motion and fresh-frame controls

The [wall analysis](evidence/m3-apple-temporal-motion.json) uses the 30 retained cup-shot frames, 1498–1527, to check whether source motion explains the measured brightness variation. Translation is estimated from original luminance using two reference frames and adjacent architectural detail. Original-only edge/correspondence masks retain the same pixels throughout the shot; both primary masks cover about 83% of the historical wall region. Registration brightness parameters are never applied to measured luminance. Five synthetic/interpolation controls pass, and an independent replay verifies the masks and arithmetic. The stricter masks cover less than the declared 25% minimum and remain excluded.

At frames 1526→1527, aligned original mean luminance falls by 0.039–0.041 nit while enhanced luminance falls by 0.977–0.983 nit. The enhancement residual changes by 0.938–0.942 nit, compared with 0.926 nit in the historical unaligned region. Identity luminance in the wall region agrees with original within 0.000003815 nit after identical alignment and masking. The predefined nine ±1-pixel offsets still leave adjacent residual intervals separated by at least 0.903 nit. This sampled sensitivity is not a continuous motion bound. [Trajectory plot (PDF)](evidence/m3-apple-temporal-motion.pdf) and [scalar measurements (CSV)](evidence/m3-apple-temporal-motion.csv) retain the controls and excluded configurations.

Two independent fresh-frame runs at 1526 and 1527 use the same benchmark binary, model, source payloads and processing settings as the continuous capture. Original, proxy and identity views match byte for byte; enhanced views differ. Across the whole historical wall region, the adjacent enhancement-residual change is −1.999 nits fresh versus −0.926 nit continuous. Fresh processing changes both history and the noise index, so it isolates neither mechanism. Both processes exit cleanly and all frozen files remain unchanged.

The tested translations do not explain the extra variation. The smooth wall, uncertain local motion/parallax and absence of captured internal model output, flow and confidence prevent a sole-cause diagnosis. These measurements establish neither a reconstruction/model defect nor acceptable flicker. Broader temporal content, full-resolution quality and physical HDR inspection remain open; no runtime algorithm or perceptual threshold changes follow from this audit.
