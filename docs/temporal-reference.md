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

Optional settings are `--frames`, `--strength`, `--colour-strength`, `--maximum-luminance-ratio`, `--reference-white`, `--motion` and `--maximum-output-bytes`. Defaults are all supplied frames, strength 1, colour strength 1, ratio 2, white 203 nits, automatic optical flow and 2 GiB. Motion also accepts `videotoolbox`, `vision` and `zero`; `zero` disables optical flow and must not be represented as an automatic-flow result. Processing dimensions default to 160 × 96 and may contain at most 512 × 288 pixels. Temporal mode, float16 model precision and scene-cut threshold 0.3 remain fixed.

Four Float32 RGB views require `frames × width × height × 48` bytes. Preflight reserves another 4 MiB for bounded manifests and frame metadata, within the selected maximum of 2 GiB. The capture processes one frame at a time and writes one view at a time; the model and its temporal state persist. It explicitly limits MLX's free allocation cache to 256 MiB. These are output, processing and cache policies, not a hard process-memory limit.

Each frame directory is staged before atomic publication. The run manifest records only published frames and remains `complete: false` until all selected frames finish and the input manifest/model hashes are rechecked. A failed or interrupted run is preserved as incomplete; it is not resumable because reconstructing temporal state would require replay. Use a new output directory for a repeat.

The report records source identity, exact PTS/duration, frame index, generation, settings, model files, implementation/binary hashes, Metal device, completed stage wall times, allocation snapshots and full-view hashes/statistics. All four views are generated from one result, without a second neural submission. `historyReset` combines input/geometry discontinuities and detected cuts. `knownInputDiscontinuities` identifies cold start, skipped source indices and PTS gaps exceeding the processor's existing threshold; it does not claim a specific internal reset reason. The public result does not expose cut scores or the selected automatic optical-flow backend.

## CPU review artifacts

```sh
uv run --frozen python scripts/review-reference-sequence.py \
  artifacts/temporal-reference/manifest.json \
  --output artifacts/temporal-reference-review
open artifacts/temporal-reference-review/index.html
```

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
