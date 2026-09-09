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

Stored Float32 linear BT.2020 nit pixels are packed into CPU-complete IOSurface-backed RGBA16F buffers. The output lease owns this independent storage through GPU presentation, allowing the disk lease to be released safely afterward. Values outside finite binary16 representation fail explicitly. This playback conversion is disk I/O plus a CPU conversion/upload boundary; it is not advertised as a zero-copy cache path. The current preparation writer starts from completed RGBA16F, whose values round-trip exactly through Float32 storage.

Missing ranges return retained-original HDR through a persistent processor with `modelURL = nil` and strength zero. No neural model is constructed for misses. Progress reports `lastOutput = "original"` or `"prepared"`, exact last frame/PTS, hit/miss counts, configuration/job state, completed work and errors. The host must show original/preparing state visibly; an original miss must not be presented as enhanced playback. For the exact displayed state, use immutable `fe_output_content_kind(output)` on that output lease: unknown (0), original (1), enhanced (2), prepared original (3), or prepared enhanced (4). The context progress snapshot may refer to a later queued frame and must not label a held display frame. Cache failures are reported rather than converted into unchecked hits.

`completedRanges` describes work completed by the current job. `availableRanges` reflects the current committed index after LRU eviction, and is the field intended for timeline coverage. This index snapshot is only progress information; acquisition/read validation remains mandatory before playback. A bounded cache may evict older prepared segments during a long job.

## Decoder provider boundary

`fe_prepared_create` selects `NativeFramePreparationProvider`. Its media capability is AVFoundation's, and the current player gates this backend to local MP4/M4V/MOV and the first video track. This is not a claim of Prepared support for all formats mpv plays.

`fe_prepared_create_with_decoder` accepts the copied `fe_preparation_decoder_provider` vtable from [frame_engine.h](../packages/CFrameEngine/include/frame_engine.h). Its identifier must include the decoder version, stream interpretation, PTS rebasing and missing-duration policy that affect playback. The provider owns independent background readers; it must not call a live playback decoder graph from another thread.

| Callback | Contract |
|---|---|
| `open` | Open actual local source and selected video ordinal. Inventory mode scans the whole track; pixel mode decodes every frame in exact `[preroll,end)`. Seeking earlier for codec recovery is internal. |
| `next` | Return one borrowed descriptor with `FE_ACCEPTED`, EOF with `FE_EMPTY`, or an explicit error/cancellation. Inventory descriptors contain PTS, duration and geometry; pixel descriptors also contain retained-compatible immutable CVPixelBuffer storage. |
| `cancel` | Thread-safe, nonblocking I/O interruption; may overlap `next`. |
| `close` | Release the reader exactly once after any in-flight callback finishes. |

Each reader's open/next/close callbacks run serially on a dedicated utility queue; different readers may overlap. The bridge immediately retains borrowed CVPixelBuffer and optional owner before advancing the reader. User state has paired retain/release callbacks. The provider code must remain loaded until every context is idle and destroyed. There is no decoder fallback on failure or a timing mismatch.

The selected-core mpv/FFmpeg provider is being integrated separately. Its availability must remain gated until real container decode, preparation, exact cache hits and presentation are verified. No full-file temporary remux or rawvideo timing guesses are used by this contract.

## Shutdown and evidence

Cancel preparation, close every playback session, asynchronously poll both `fe_session_is_idle` and `fe_prepared_is_idle`, release output leases, and destroy the session/context before process or library teardown. Ordinary destruction is nonblocking and retained asynchronous work keeps its context alive.

The real-PQ test prepares six frames across two segments, reads exact PTS/duration cache hits, resets generation, falls back to original outside coverage, then reuses both completed segments without processing more frames. A separate real Neural Rendering test cancels an incomplete segment, resumes from deterministic preroll, and compares nine cached frames including the boundary to independent continuous recomputation. On Apple M3 the measured difference was zero nits, with a normalized test tolerance of 0.002. These tests establish numeric behavior, not physical display accuracy or sustained throughput.

The mpv adapter's two-process MP4 test verified cache hits, original misses, generation changes and completed-segment reuse. The native app's 11-check Prepared smoke verified capacity replacement, cancellation/resume, neural cache output, coverage seeking and completed-job reuse. CPU tests additionally cover exact millisecond/VFR timing, missing inventory entries, legacy recovery, blocked-decoder cancellation and borrowed-storage ownership.

```sh
source scripts/env.sh
swift test --filter 'prepared|preparationProvider|preparationContext|cache'
```
