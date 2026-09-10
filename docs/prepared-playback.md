# Prepared playback through the shared engine

`PreparedHDRContext` connects the existing `HDRPreparationCoordinator` and `HDRSegmentCache` to normal `FrameSession` playback. One context owns one source, immutable neural configuration and cache directory. Preparation publishes complete segments into the same cache actor that playback reads.

## Configuration and identity

The adapter passes this JSON and the actual opened file path to `fe_prepared_create`:

```json
{
  "sourcePath": "/absolute/path/hdr10-30.mp4",
  "cacheDirectory": "/absolute/path/prepared-cache",
  "capacityBytes": 8589934592,
  "rangeStart": { "value": 0, "timescale": 30 },
  "rangeEnd": { "value": 60, "timescale": 30 },
  "segmentFrames": 60,
  "prerollFrames": 8
}
```

Range bounds are optional; omission selects the complete video track. Bounds must coincide with exact source PTS or the final frame end. A segment contains at most `segmentFrames` source frames, default 60, preceded by up to `prerollFrames` deterministic history frames, default 8. Both limits are bounded to 600; segment count must be positive. Timestamp planning uses the selected decoder provider's exact inventory and fixed coded geometry. The native backend scans compressed output timestamps, applying track edits and skipping marker buffers. External providers may decode into bounded temporary storage to obtain the same reordered timing as playback. Only the timing inventory is retained, with a maximum of one million frames and 100,000 planned segments. Preroll uses shared slices of that inventory instead of duplicating histories per segment. Duplicate PTS and changing coded geometry are rejected explicitly; gaps or overlaps between a frame's duration and the next frame's PTS are preserved.

Segments partition coverage at the next segment's first PTS. For example, PTS `0/1000`, `33/1000`, `67/1000` with duration `1/30` remain those exact rational values. The timing inventory's SHA-256 is part of the cache key. Preparation verifies every decoded preroll and output frame against the indexed PTS/duration before publishing; a missing, extra or changed frame fails the job.

The C boundary compares canonical, symlink-resolved source paths. The playback adapter must obtain the actual path from its playback core and restrict selection to the first video track, which is the selection currently supported by the adapters. Decoder implementations and exact timing policies have separate identities. A manually supplied cache identity cannot authorize reuse for another opened file or track.

Initialization hashes full source contents and actual model weights. The generated [cache identity](hdr-cache.md) also records stream interpretation, processing/output dimensions, HDR reference white, proxy/reconstruction policy, every exposed effect, fixed guide/temporal defaults, precision, implementation version, exact range and deterministic preroll. Cached pixels precede display mapping, so window size and display headroom do not invalidate them. Changing source, model or settings creates a new context/session and resets playback generation. Device, inode, size and nanosecond modification/change timestamps are checked around hashing/indexing, before reuse and preparation, and before publication. Observed source mutation invalidates the context and requires reopening the media.

A weak process-wide registry shares the owning cache actor when filter replacement briefly overlaps contexts for the same canonical directory and capacity. Different source/settings identities coexist in that actor. Capacity changes require draining old contexts first. The filesystem lock remains exclusive across processes.

## Asynchronous control and playback

```c
fe_prepared *prepared = fe_prepared_create(&config, json, actual_source_path, error, sizeof(error));
fe_session *playback = fe_prepared_session_create(prepared, error, sizeof(error));
fe_prepared_start(prepared);
/* Submit decoded frames and poll completed output using the ordinary session API. */
/* Poll fe_prepared_progress_json(prepared, ...) for job/range/output state. */
```

Creation validates configuration synchronously and initializes fingerprints, timestamp planning and cache recovery in the background. The progress getter reads a small locked snapshot; it never waits for an actor, disk I/O or inference. Start/cancel requests use monotonically ordered control tokens, so an immediate cancellation also invalidates a start that has not reached the actor yet. Restart skips only complete segments acquired under their exact expected identity. Cancellation interrupts initialization/inventory reads and waits for admitted preparation work before reporting job cancellation; partial staging is discarded. A cancelled inventory can be initialized again on resume.

`PreparedFrameProcessor` looks up the decoded frame's exact rational PTS **and** duration. It validates and pins a completed segment once on entry, reuses that lease within the segment, and releases it when leaving the range or resetting generation. Reads verify individual payloads. A cache hit returns through the ordinary `ProcessedFrame` and `CompletedFrame` ownership path; mpv retains its existing playback clock and presenter. Repeated cache reads do not evaluate a neural model or advance neural history.

Stored Float32 linear BT.2020 nit pixels are packed into CPU-complete IOSurface-backed RGBA16F buffers. Cache reads copy validated bytes into aligned Float32 storage; vImage converts all RGBA components while preserving the destination row stride. Small C loops check finite values and straight alpha without per-component Swift collection overhead. SHA-256 checks, full-segment validation on acquisition and individual payload validation on every read remain mandatory. Half-float overflow fails explicitly; negative RGB, signed zero and subnormal values retain IEEE conversion behavior. The output lease owns this independent storage through GPU presentation, allowing the disk lease to be released safely afterward. This is a disk read plus CPU conversion/upload boundary. The current preparation writer starts from completed RGBA16F, whose values round-trip exactly through Float32 storage.

Missing ranges return retained-original HDR through a persistent processor with `modelURL = nil` and strength zero. No neural model is constructed for misses. Progress reports `lastOutput = "original"` or `"prepared"`, exact last frame/PTS, hit/miss counts, configuration/job state, completed work and errors. The host must show original/preparing state visibly; an original miss must not be presented as enhanced playback. For the exact displayed state, use immutable `fe_output_content_kind(output)` on that output lease: unknown (0), original (1), enhanced (2), prepared original (3), or prepared enhanced (4). The context progress snapshot may refer to a later queued frame and must not label a held display frame. Cache failures are reported rather than converted into unchecked hits.

`completedRanges` describes work completed by the current job. `availableRanges` reflects the current committed index after LRU eviction, and is the field intended for timeline coverage. This index snapshot is only progress information; acquisition/read validation remains mandatory before playback. A bounded cache may evict older prepared segments during a long job.

## Decoder provider boundary

`fe_prepared_create` selects `NativeFramePreparationProvider`, whose media capability is AVFoundation's. The standalone native harness uses this backend for supported MP4/M4V/MOV files and the first video track. The mpv player supplies its own selected-core provider through the following API.

`fe_prepared_create_with_decoder` accepts the copied `fe_preparation_decoder_provider` vtable from [frame_engine.h](../packages/CFrameEngine/include/frame_engine.h). Its identifier must include the decoder version, stream interpretation, PTS rebasing and missing-duration policy that affect playback. The provider owns independent background readers; it must not call a live playback decoder graph from another thread.

| Callback | Contract |
|---|---|
| `open` | Open actual local source and selected video ordinal. Inventory mode scans the whole track; pixel mode decodes every frame in exact `[preroll,end)`. Seeking earlier for codec recovery is internal. |
| `next` | Return one borrowed descriptor with `FE_ACCEPTED`, EOF with `FE_EMPTY`, or an explicit error/cancellation. Inventory descriptors contain PTS, duration and geometry; pixel descriptors also contain retained-compatible immutable CVPixelBuffer storage. |
| `cancel` | Thread-safe, nonblocking I/O interruption; may overlap `next`. |
| `close` | Release the reader exactly once after any in-flight callback finishes. |

Each reader's open/next/close callbacks run serially on a dedicated utility queue; different readers may overlap. The bridge immediately retains borrowed CVPixelBuffer and optional owner before advancing the reader. User state has paired retain/release callbacks. The provider code must remain loaded until every context is idle and destroyed. There is no decoder fallback on failure or a timing mismatch.

The [selected-core mpv/FFmpeg provider](mpv-adapter.md#prepared-playback) opens an independent instance of the actual playback demuxer and a separate VideoToolbox decoder. It preserves native Matroska's explicit/missing duration distinction and the playback core's timestamp rebasing. Real neural MP4, Matroska and variable-rate Matroska tests verify preparation, exact hits, original misses and restart reuse. Variable-rate cancellation/resume also verifies that incomplete work remains unpublished. No full-file temporary remux or rawvideo timing guesses are used.

For a source with a nonzero container origin, original-file inventory PTS and decoder/cache PTS can differ. mpv applies the selected core's packet offset before decoding; the independent provider copies that exact offset and binds it in the cache identity together with its native revision. Cache ranges use the resulting decoder timeline. The exporter separately describes decoder-to-player mapping. The [Apple nonzero-start regression](apple-hdr-playback.md#prepared-nonzero-start-regression) verifies both coordinates, exact duration digests and zero-work reopening with six full-resolution float cache frames. Its six opening source frames are black, so this test establishes timing/cache integration rather than natural-scene reconstruction quality.

## Shutdown and evidence

Cancel preparation, close every playback session, asynchronously poll both `fe_session_is_idle` and `fe_prepared_is_idle`, release output leases, and destroy the session/context before process or library teardown. Ordinary destruction is nonblocking and retained asynchronous work keeps its context alive.

The real-PQ test prepares six frames across two segments, reads exact PTS/duration cache hits, resets generation, falls back to original outside coverage, then reuses both completed segments without processing more frames. A separate real Neural Rendering test cancels an incomplete segment, resumes from deterministic preroll, and compares nine cached frames including the boundary to independent continuous recomputation. On Apple M3 the measured difference was zero nits, with a normalized test tolerance of 0.002. These tests establish numeric behavior, not physical display accuracy or sustained throughput.

The mpv adapter's two-process MP4 test verified cache hits, original misses, generation changes and completed-segment reuse. The native app's 11-check Prepared smoke verified capacity replacement, cancellation/resume, neural cache output, coverage seeking and completed-job reuse. CPU tests additionally cover exact millisecond/VFR timing, missing inventory entries, legacy recovery, blocked-decoder cancellation and borrowed-storage ownership.

```sh
source scripts/env.sh
swift test --filter 'prepared|preparationProvider|preparationContext|cache'
```

## Sustained M3 playback

```sh
source scripts/env.sh
python3 scripts/test-mpv-prepared-playback.py \
  --source assets/test-clips/playback/pq-30-60s.mkv \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 160 --height 96 --prepare-seconds 6 --play-seconds 30 \
  --segment-frames 60 --preroll-frames 8 --capacity-mib 512 \
  --report artifacts/mpv-prepared-sustained-run.json
```

Use a new report path. The test prepares 180 real Neural Rendering outputs in three segments from a 320×192, 30 fps PQ source with audio, then plays for 30 wall-clock seconds through cached coverage into original output. Native drawable size is 960×496. Nine paused seeks target the exact source frame immediately before, at and after 2-, 4- and 6-second boundaries. A second process reopens the cache and must reuse all three segments without processing another frame. Reports include exact source/weight/binary hashes, source revision state, cache payload checksums, sampled resources, per-span pacing and scheduled audio-minus-video offsets.

The [compact before/after evidence](evidence/m3-prepared-sustained-playback.json) preserves the failed initial run and the optimized result on Apple M3, 16 GiB, macOS 26.5. Both use Swift debug builds and record modified root source trees. The optimized run also uses the scoped CoreAudio pause-tail patch in mpv; end-to-end timing therefore reflects both changes. The completed cache wall stages isolate the cache CPU improvement. Exact binary hashes remained unchanged within each run.

| Measurement | Initial cache loops | Bulk copy / vImage |
|---|---:|---:|
| Overall source/media advance per wall second | 0.7850 | 0.9968 |
| Cache read median / p95 | 37.93 / 39.34 ms | 2.52 / 3.42 ms |
| Float16 pack median / p95 | 23.28 / 23.96 ms | 0.84 / 1.30 ms |
| Cache read maximum, including segment acquisition | 747.14 ms | 81.36 ms |
| Cached segment 0 / 1 / 2 sampled rate | 0.450 / 0.452 / 0.545 | 0.962 / 0.967 / 1.010 |
| Uncached original sampled rate | 0.9992 | 0.9999 |
| Sampled cached buffering time | 6.32 s | 0.032 s |
| Steady maximum absolute A/V offset | 9.667 ms | 8.900 ms |
| Startup maximum absolute A/V offset | 29.698 ms | 29.700 ms |
| Decoder / VO frame-drop deltas | 0 / 0 | 0 / 0 |

The source-rate criterion is 0.97–1.03 over the complete 30-second run. Per-segment ratios use quantized media-clock endpoints over approximately two seconds and remain diagnostics; the first two optimized spans do not independently satisfy 0.97. The 20 ms A/V criterion excludes the first two seconds. Startup exceeded that target and remains reported separately. Optimized steady p95 absolute offset was 0.018 ms and first-to-last-quarter median drift was 0.005 ms. These values come from mpv's queued clock state, not physical scanout or independent acoustic measurement.

The optimized run produced every exact source PTS through 29.9 seconds: 898 completed outputs with no duplicate or missing timestamps before the last displayed frame. All nine seek pairs matched; observed pair readiness was 61.7–129.6 ms. Restart reused three complete segments, processed zero frames, and preserved every payload and manifest checksum. Cached output and original misses carried their correct per-output content kinds through the same clock and float renderer.

Frame reservations peaked at three slots and 8,665,536 bytes against the 512 MiB session budget. Cache usage was 176,995,284 of 536,870,912 bytes, with no partial staging after completion. Model payload accounting peaked at 291,576,650 bytes against the separate 1 GiB policy. Preparation sampled process RSS peaked at 787,267,584 bytes; completed-playback samples peaked at 657,965,056 bytes. Reported MLX peak active memory was 595,088,980 bytes and cache memory 262,455,834 bytes. RSS sampling does not establish a hard transient allocation bound; model payload, frame reservations and allocator cache are distinct budgets. Both playback processes exited cleanly. Held-consumer and model-credit drain guarantees have separate [lifecycle stress evidence](frame-stress.md).

Eighteen focused CPU tests cover cache corruption, capacity and exact timing together with the optimized conversion. All 63,488 finite binary16 encodings and selected midpoint neighbours match scalar `Float16` bit patterns. Additional cases cover negative zero, subnormal underflow, overflow rejection, unaligned Float32 bytes, nonfinite values in every channel, invalid alpha and untouched row padding. Larger source/processing workloads, additional audio devices and physical display timing retain their separate qualification requirements.
