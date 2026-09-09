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

Range bounds are optional; omission selects the complete video track. Bounds must coincide with exact source frame boundaries. A segment contains at most `segmentFrames` source frames, default 60, preceded by up to `prerollFrames` deterministic history frames, default 8. Both limits are bounded to 600; segment count must be positive. Timestamp planning reads compressed sample metadata, applies track edits through output timestamps, skips marker-only buffers and sorts decode order into presentation order. It retains no decoded pixels. The timestamp inventory is bounded to one million frames. Inputs with gaps, overlapping presentation times or grouped compressed samples are currently rejected explicitly.

The C boundary compares canonical, symlink-resolved source paths. The playback adapter must obtain the actual path from its playback core and restrict selection to the first video track, which is the track supported by `NativeHDRVideoReader`. A manually supplied cache identity cannot authorize reuse for another opened file or track.

Initialization hashes full source contents and actual model weights. The generated [cache identity](hdr-cache.md) also records stream interpretation, processing/output dimensions, HDR reference white, proxy/reconstruction policy, every exposed effect, fixed guide/temporal defaults, precision, implementation version, exact range and deterministic preroll. Cached pixels precede display mapping, so window size and display headroom do not invalidate them. Changing source, model or settings creates a new context/session and resets playback generation.

## Asynchronous control and playback

```c
fe_prepared *prepared = fe_prepared_create(&config, json, actual_source_path, error, sizeof(error));
fe_session *playback = fe_prepared_session_create(prepared, error, sizeof(error));
fe_prepared_start(prepared);
/* Submit decoded frames and poll completed output using the ordinary session API. */
/* Poll fe_prepared_progress_json(prepared, ...) for job/range/output state. */
```

Creation validates configuration synchronously and initializes fingerprints, timestamp planning and cache recovery in the background. The progress getter reads a small locked snapshot; it never waits for an actor, disk I/O or inference. Start/cancel requests use monotonically ordered control tokens, so an immediate cancellation also invalidates a start that has not reached the actor yet. Restart skips only complete segments acquired under their exact expected identity. Cancellation waits for admitted preparation work before reporting job cancellation; partial staging is discarded.

`PreparedFrameProcessor` looks up the decoded frame's exact rational PTS **and** duration. It validates and pins a completed segment once on entry, reuses that lease within the segment, and releases it when leaving the range or resetting generation. Reads verify individual payloads. A cache hit returns through the ordinary `ProcessedFrame` and `CompletedFrame` ownership path; mpv retains its existing playback clock and presenter. Repeated cache reads do not evaluate a neural model or advance neural history.

Stored Float32 linear BT.2020 nit pixels are packed into CPU-complete IOSurface-backed RGBA16F buffers. The output lease owns this independent storage through GPU presentation, allowing the disk lease to be released safely afterward. Values outside finite binary16 representation fail explicitly. This playback conversion is disk I/O plus a CPU conversion/upload boundary; it is not advertised as a zero-copy cache path. The current preparation writer starts from completed RGBA16F, whose values round-trip exactly through Float32 storage.

Missing ranges return retained-original HDR through a persistent processor with `modelURL = nil` and strength zero. No neural model is constructed for misses. Progress reports `lastOutput = "original"` or `"prepared"`, exact last frame/PTS, hit/miss counts, configuration/job state, completed work and errors. The host must show original/preparing state visibly; an original miss must not be presented as enhanced playback. For the exact displayed state, use immutable `fe_output_content_kind(output)` on that output lease: unknown (0), original (1), enhanced (2), prepared original (3), or prepared enhanced (4). The context progress snapshot may refer to a later queued frame and must not label a held display frame. Cache failures are reported rather than converted into unchecked hits.

`completedRanges` describes work completed by the current job. `availableRanges` reflects the current committed index after LRU eviction, and is the field intended for timeline coverage. This index snapshot is only progress information; acquisition/read validation remains mandatory before playback. A bounded cache may evict older prepared segments during a long job.

## Shutdown and evidence

Cancel preparation, close every playback session, asynchronously poll both `fe_session_is_idle` and `fe_prepared_is_idle`, release output leases, and destroy the session/context before process or library teardown. Ordinary destruction is nonblocking and retained asynchronous work keeps its context alive.

The focused real-PQ test prepares six frames across two three-frame segments, reads six exact-timestamp HDR cache hits, resets generation and repeats a cached frame, falls back to original outside the range, then restarts preparation and reuses both segments without processing another frame. The initial run passed in 1.165 seconds on Apple M3. It verifies finite float HDR values above 203 nits and the common output format; it does not establish display accuracy or sustained playback throughput.

```sh
source scripts/env.sh
swift test --filter 'preparedPlayback|preparedControl|preparedCControls'
```

Actual mpv option/control wiring and native presentation must also be validated with the same source, neural settings and source/display dimensions before treating Prepared mode as integrated playback.
