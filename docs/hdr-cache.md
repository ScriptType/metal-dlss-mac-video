# Persistent HDR segment cache

`HDRSegmentCache` stores complete frame ranges as Float32 RGBA in linear BT.2020, with RGB measured in absolute cd/m². Negative reconstruction excursions, wide-gamut channels, dark values and HDR highlights retain their float bit patterns. Alpha is straight and must be finite in 0…1. NaN and infinity are rejected. Float storage is the current cache format; the evaluated HDR10 alternative below is not used by playback.

## Identity and temporal reproducibility

The SHA-256 key covers the canonical JSON representation of `HDRCacheIdentity`:

| Field | Required contents |
|---|---|
| Source | Full content SHA-256, byte length, video stream index and decoder/crop/orientation interpretation |
| Range | Exact start and end timestamps; equivalent rational fractions have identical keys |
| Model and implementation | Model SHA-256, implementation version |
| Dimensions | Processing and output width/height |
| Colour policy | Source interpretation, working units/primaries, proxy/reconstruction policy, reference white and any baked display mapping |
| Guides and effects | Guide algorithms/dimensions/content hashes; every effect and strength |
| Execution | Quality/precision, numerical backend or other execution choices that can change pixels |
| Temporal context | Preroll start, reset policy version and random seed |

Callers must supply every pixel-affecting setting. The cache cannot infer omitted settings from a renderer. `HDRCacheSource.fingerprint` hashes source content in bounded chunks and rejects a source whose size or modification time changes during hashing.

At each segment's preroll start, preparation must reset temporal history and the random seed, process every source frame sequentially, and discard output preceding the segment start. Reusing an uncontrolled live history is incompatible with this identity. A different preroll start or reset policy produces a different key. Segment durations and timestamps remain rational, including variable-frame-rate input; overflow is rejected rather than rounded.

## Storage and ownership

```text
cache/
  cache.lock
  staging/<writer UUID>/<frame files and optional manifest>
  segments/<identity SHA-256>/manifest.json
  segments/<identity SHA-256>/00000000.rgba32f
```

One actor owns one directory, enforced by an operating-system advisory lock. Open with `try await HDRSegmentCache.open(directory:capacityBytes:)`, or call `recover()` after the initializer. Recovery removes abandoned staging, validates committed segments, removes corrupt entries and reconstructs the completed-range index. No independently updated index can publish a partial segment.

`begin(identity:expectedFrameCount:)` allocates a writer. Append one `HDRCacheFloatFrame` at a time, with contiguous presentation times and positive durations. Each frame file is interleaved little-endian RGBA32F. Frame data is synchronized to disk while still unpublished. `publish` requires the exact frame count and range coverage, writes the manifest, verifies every payload's dimensions, float values and SHA-256, synchronizes staging, then renames the directory into `segments` on the same filesystem. An interrupted write remains unpublished; a published segment is independently recoverable. `cancel` discards a live writer.

The manifest records schema/storage-policy versions, the complete identity, frame filenames, rational timing, byte counts and SHA-256 checksums. Unexpected files, symlinks, noncontiguous timing, invalid float values and checksum/size mismatches are rejected.

`acquire(identity:)` validates and pins a completed segment. Use `read(_:frameIndex:)` for one frame at a time and call `release` when the reader finishes. Repeated reads preserve timestamps and do not advance temporal history. Active leases prevent eviction. Corruption detected after acquisition causes reads to fail; it does not return unchecked pixels.

The configured capacity bounds the logical bytes of both staged and completed payloads plus metadata. It excludes filesystem allocation-unit overhead. Least recently used completed entries are evicted when unpinned. If staged data or active readers prevent sufficient eviction, writes fail with `capacityExceeded`. No over-budget entry is published. Processing retains at most one caller-supplied frame plus serialization buffers and bounded manifest metadata; this disk store does not allocate GPU work.

`completedRanges(source:settings:)` returns validated ranges, preroll descriptions, frame counts and keys for progress and resumption. A preparation job skips a range only after acquiring its complete expected identity, including preroll. Partial segments are regenerated from deterministic preroll. Playback clock integration, job scheduling, cancellation of GPU work and transitions across cached ranges belong to Prepared mode (#14).

## HDR10 policy evaluation

Run the repeatable evaluation with installed `ffmpeg`/`ffprobe` and a libx265 encoder:

```sh
python3 scripts/evaluate-hdr10-cache.py
```

Outputs in `artifacts/hdr-cache-evaluation/` include the float reference, explicit quantized YUV reference, encoded MP4 files, decoded YUV frames and `report.json`. The fixture is twelve 64×64 frames at 24 fps, containing BT.2020 red/green/blue/yellow patches and grey values from 0.0001 to 10,000 nits. Float SHA-256: `7119e2d4676d0cbf24fadc8e7214c64c18bbd5082c87be67afa58676daa7cd39`.

The evaluated policy applies ST2084 to absolute RGB nits, converts with the BT.2020 nonconstant-luminance matrix, quantizes to limited-range 10-bit YCbCr and uses center-sited 2×2 box-filtered 4:2:0 chroma. HEVC Main10 is stored in MP4 with an `hvc1` tag, explicit `colr` metadata and a 24,000-Hz track timescale. Input frame tags, encoder options and bitstream VUI all declare BT.2020/PQ/limited range; output options alone do not reliably carry input frame colour tags in the evaluated FFmpeg build. Mastering metadata declares the synthetic BT.2020/D65 volume, 0…10,000-nit bounds, MaxCLL 10,000 and frame-average light level 1,104 nits.

Evaluation verifies stream and every decoded frame's colour metadata, profile, frame count and exact presentation timestamp. It checks static HDR metadata, decodes YUV without an implicit SDR conversion, independently reconstructs RGB nits, and measures channel errors. The lossless encoder must preserve the already quantized YUV byte-for-byte. Grey/chroma quantization precedes encoding and remains lossy relative to float.

Measured with FFmpeg 9.0.1 on the fixture:

| Encoding | File bytes | Mean absolute RGB error | Maximum RGB error | Decoded peak |
|---|---:|---:|---:|---:|
| Float reference | 786,432 | 0 | 0 | 10,000 nits |
| HEVC lossless YUV | 7,152 | 1.774 nits | 14.718 nits | 10,000 nits |
| HEVC CRF 12 | 6,393 | 1.793 nits | 39.058 nits | 10,000 nits |

These sizes describe a static synthetic chart, not natural-video compression performance. Regression limits are 25-nit maximum channel error for lossless YUV and 100 nits for CRF 12 on this fixture; they are not a general perceptual acceptance threshold.

HDR10 cannot preserve negative RGB, values above 10,000 nits or alpha. The candidate conversion rejects out-of-domain RGB rather than silently clipping it. Chroma subsampling loses spatial colour detail, even when HEVC is lossless. Production adoption therefore requires an explicit gamut/luminance policy, temporal and colour-edge qualification on natural clips, metadata computed for each transformed segment, and timestamp handling for VFR. Float storage remains the usable default and reference until that policy is qualified and integrated.

## Checks

```sh
source scripts/env.sh
swift test --filter cache
python3 scripts/evaluate-hdr10-cache.py
```

`HDRCacheTests.swift` covers bit-exact HDR float round trips, full identity invalidation and canonical rational equivalence, VFR timing, incomplete writes/recovery, payload corruption, invalid pixels, active-reader eviction protection, source fingerprints and exclusive cache ownership.
