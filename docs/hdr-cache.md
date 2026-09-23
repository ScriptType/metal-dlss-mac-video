# Persistent HDR segment cache

`HDRSegmentCache` stores complete frame ranges. The identity's `colourPolicy["storage"]` selects the frame format, so the format is part of every cache key. Prepared playback stores 10-bit HEVC (Main10, PQ, BT.2020) encoded by VideoToolbox, described under [HEVC storage](#hevc-storage). Identities that name `HDRSegmentCache.storagePolicy`, or no storage at all, keep lossless Float32 RGBA in linear BT.2020 with RGB in absolute cd/m². That format keeps negative reconstruction excursions, wide-gamut channels, dark values and HDR highlights bit for bit, and it is the reference for the HEVC tolerance test. Its alpha is straight and must be finite in 0…1. NaN and infinity are rejected.

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
| Timing inventory | For schema 2, SHA-256 of the complete ordered canonical PTS/duration array |

Callers must supply every pixel-affecting setting. The cache cannot infer omitted settings from a renderer. `HDRCacheSource.fingerprint` hashes source content in bounded chunks and rejects a source whose size or modification time changes during hashing.

At each segment's preroll start, preparation must reset temporal history and the random seed, process every source frame sequentially, and discard output preceding the segment start. Reusing an uncontrolled live history is incompatible with this identity. A different preroll start or reset policy produces a different key. Segment durations and timestamps remain rational, including variable-frame-rate input; overflow is rejected rather than rounded.

## Storage and ownership

```text
cache/
  cache.lock
  staging/<writer UUID>/<frame files and optional manifest>
  segments/<identity SHA-256>/manifest.json
  segments/<identity SHA-256>/00000000.hevc      HEVC policy
  segments/<identity SHA-256>/00000000.rgba32f   Float32 policy
```

One actor owns one directory, enforced by an operating-system advisory lock. Open with `try await HDRSegmentCache.open(directory:capacityBytes:)`, or call `recover()` after the initializer. Recovery removes abandoned staging, validates committed segments, removes corrupt entries and reconstructs the completed-range index. No independently updated index can publish a partial segment.

`begin(identity:expectedFrameCount:)` allocates a writer and rejects an unknown storage policy. Append one `HDRCacheFloatFrame` (Float32 policy) or one `HDRCacheHEVCSample` (HEVC policy) at a time with positive duration; each append refuses the other format. Legacy schema 1 identities omit `timingInventorySHA256` and require contiguous presentation times ending exactly at the range end. Schema 2 identities bind `HDRCacheFrameTiming.inventoryDigest` for the complete expected timing array. They preserve strictly increasing PTS with durations that may overlap or leave gaps relative to the next PTS; every frame PTS must lie in the segment's coverage range. Coverage ends at the next segment's first PTS, or the final frame end for EOF. A Float32 frame file is interleaved little-endian RGBA32F. An HEVC frame file is one access unit of 4-byte length-prefixed NAL units. Frame data is synchronized to disk while still unpublished. `publish` requires the exact frame count and either complete inventory digest or legacy contiguous range coverage, writes the manifest, verifies every payload's size, content (finite floats, or exact NAL framing with VPS, SPS, PPS and an IRAP picture in frame 0) and SHA-256, synchronizes staging, then renames the directory into `segments` on the same filesystem. An interrupted write remains unpublished; a published segment is independently recoverable. `cancel` discards a live writer.

The manifest records schema/storage-policy versions, the complete identity, frame filenames, rational timing, byte counts and SHA-256 checksums. Unexpected files, symlinks, missing/altered inventory records, noncontiguous legacy timing, invalid float values and checksum/size mismatches are rejected. Recovery validates the same timing policy as publication. Schema 1 identity encoding and keys are unchanged when the optional digest is absent; schema 2 is explicitly versioned so an older reader cannot mistake it for contiguous data.

`acquire(identity:)` validates and pins a completed segment. Use `read(_:frameIndex:)` (Float32) or `readSample(_:frameIndex:)` (HEVC) for one frame at a time and call `release` when the reader finishes. Repeated reads preserve timestamps and do not advance temporal history. Active leases prevent eviction. Corruption detected after acquisition causes reads to fail; it does not return unchecked pixels.

The configured capacity bounds the logical bytes of both staged and completed payloads plus metadata. The actor sums the byte counts it recorded at append, publication and validation, so accounting never walks the directory. Foreign files and filesystem allocation-unit overhead do not count. Least recently used completed entries are evicted when unpinned. If staged data or active readers prevent sufficient eviction, writes fail with `capacityExceeded`. No over-budget entry is published. Processing retains at most one caller-supplied frame plus serialization buffers and bounded manifest metadata; this disk store does not allocate GPU work.

`completedRanges(source:settings:)` returns validated ranges, preroll descriptions, frame counts and keys for progress and resumption. A preparation job skips a range only after acquiring its complete expected identity, including preroll. Partial segments are regenerated from deterministic preroll. Playback clock integration, job scheduling, cancellation of GPU work and transitions across cached ranges belong to Prepared mode (#14).

## HEVC storage

Production identities set `colourPolicy["storage"] = HDRCacheHEVC.storagePolicy`. Preparation appends completed linear-nits RGBA16F frames to an `HDRCacheSegmentWriter` and publishes. Playback asks an `HDRCacheFrameReader` for frame *i* of a lease and gets a linear-nits RGBA16F IOSurface buffer back. Neither caller sees HEVC samples, VideoToolbox or P010.

A Metal kernel converts each frame to 10-bit video-range BT.2020 NCL PQ with 4:2:0 chroma. ST 2084 is a 65,536-entry table indexed by the Float16 bit pattern, so it is exact for every input. RGB is clipped per channel to 0–10,000 nits; NaN, infinity and alpha other than 1 reject the frame. Each 2×2 block keeps the chroma of its top-left pixel, which the importer's top-left bilinear reconstruction returns exactly. A hardware `VTCompressionSession` per segment encodes Main10 without frame reordering: VBR at 8 Mbit/s with a 9 Mbit/s VBV maximum (scaled up by output area above 1080p), 40 frames of look-ahead, spatial adaptive QP off, and an IDR at frame 0. Look-ahead also places IDRs at scene cuts; decoding stays in order. Each access unit is one frame file, and frame 0 carries the VPS, SPS and PPS. The policy string spells out every one of these settings and is part of the key, so a changed setting never reads old segments. The reader keeps one decode position per lease. Sequential hits decode one frame; after a seek it decodes from the segment's frame 0 to the requested frame.

Measured on the M3 in a debug build with the retained 1080p HDR10+ reference (`apple-advanced-hdr10plus-aac.mp4`, 1920×1080 at 23.976 fps). Preparing all 2,360 frames (98.43 s) at strength 0 stores 60,226,300 bytes (57.4 MiB) per prepared minute including manifests, 8.03 Mbit/s, so a 2-hour film needs 6.73 GiB of the default 8 GiB. On frames 1488–1543 the original path's per-channel error against Float32 storage is max 140.0 nits and p99 6.76 nits; the Float32 peak is 1,635 nits, and the test requires p99 ≤ 10.53 nits (one 10-bit PQ code at 1,000 nits) and max ≤ 10 % of peak. The enhanced path measures max 97.5 nits and p99 6.0 to 6.8 nits against a 922.5-nit peak; its max rule is 15 % of peak. Without the codec, the conversion alone errs by at most 0.06 nits on the original path and 43 nits on the enhanced path, where 4:2:0 drops chroma detail the enhancement adds. A hit (read, decode, import and RGBA16F write) takes a median 6.7 ms and p95 10.1 ms. Entering a segment after a seek, acquisition included, takes 40 ms at frame 35 and 61 ms at frame 55.

Float32 segments have different keys from every HEVC identity, so production never acquires them. They are never decoded as HEVC: the reader picks the decoder from the lease's own identity, `readSample` refuses a Float32 lease, and a manifest that claims HEVC over Float32 bytes fails NAL framing and is deleted on recovery. Their older access times make them the first LRU evictions.

## HDR10 policy evaluation

This evaluation was the starting point for the HEVC policy above.

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

HDR10 cannot preserve negative RGB, values above 10,000 nits or alpha, and chroma subsampling loses spatial colour detail even when HEVC is lossless. The evaluation rejects out-of-domain RGB and uses centre-sited box chroma. The production policy clips per channel instead, decimates top-left chroma, keeps exact rational timing in the manifest, and writes no static HDR metadata.

## Checks

```sh
source scripts/env.sh
swift test --filter cache
swift test --filter "hevc|HEVC|float32Entries"
python3 scripts/evaluate-hdr10-cache.py
```

`HDRCacheTests.swift` and `HDRCacheInventoryTests.swift` cover bit-exact HDR float round trips, full identity invalidation and canonical rational equivalence, contiguous VFR and exact millisecond PTS/duration inventories, missing/changed timing rejection, legacy identity compatibility, incomplete writes/recovery, payload corruption, invalid pixels, active-reader eviction protection, source fingerprints and exclusive cache ownership. `HDRCacheHEVCTests.swift` covers the PQ table and clip policy, NAL framing, Float32 isolation with a forged HEVC manifest, the GPU exporter's codes and chroma siting, and a VFR round trip with mid-segment entry. `PreparedHEVCReferenceTests.swift` holds the tolerance and size tests on the retained reference. It skips when the reference, Metal or a hardware HEVC encoder is missing.
