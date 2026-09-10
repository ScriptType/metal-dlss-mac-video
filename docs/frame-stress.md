# Bounded frame-engine lifecycle and memory stress

The stress harness exercises real native HDR import, original/Neural Rendering processing, generation resets and Metal consumers. It complements the focused scheduler tests, which use a gated processor to check individual transitions. It runs in a separate process and finishes each generation, consumer and model owner before starting the next cycle.

```sh
python3 scripts/stress-frame-engine.py \
  --video assets/test-clips/hdr10-30.mp4 \
  --alternate-video assets/test-clips/hlg-60.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --width 160 --height 96 --cycles 12 --warmup-cycles 3 \
  --output artifacts/frame-stress/run-1
```

The default runs twelve cycles with strength zero, then twelve with strength one. Both retain the configured model URL, so the original phase also verifies that zero strength avoids neural residency. A cycle performs five real processing operations: three completed source frames, one admitted frame cancelled during its producer dependency, and one completed frame from the alternate source after reset. Source pixels retain their native geometry; only neural processing uses the supplied dimensions. Three frame slots and a 512 MiB frame reservation budget are fixed for this test. The runtime's separate model/processing/cache admission policy remains in force.

Use a fresh output directory. Clean engine sources are required by default; `--allow-dirty` labels a development run and records file hashes, working-tree state, binary/metallib hashes and revisions. Results are reproducible only with matching source clips, weights, dimensions and limits. Model/source content hashes are recorded. The wrapper enforces a bounded wall-clock timeout and retains logs plus JSON reports on failure.

## Lifecycle criteria

Every cycle must meet these conditions:

- Three completed, externally held leases fill all three slots; a fourth submission returns `FE_FULL`.
- Thirty-two redraw requests return the same completed lease without another processing call or history reset. Expired presentation deadlines do not reset history.
- Releasing one lease admits one frame. A real unsignalled Metal producer dependency keeps that admitted operation pending while the generation changes. Obsolete submissions are rejected, and cancelled work never reaches output after GPU completion.
- A new decoder/source is accepted after reset with the new generation and source identity. The temporal reset counter advances exactly once.
- A Metal blit consumer retains the remaining three leases across session close. Frame reservations remain occupied until the actual command completion callback; afterward all slots and reserved bytes return to zero.
- After the cycle returns and all admitted work/owners drain, model count and model payload credits return to zero. The next cycle starts only after this recovery. Original cycles retain zero neural models; neural cycles retain one during processing.

The report includes the common frame measurements, cancelled count, reset/close drain latency, model counters, sampled process resident memory and MLX active/cache/peak-active memory. The real GPU consumer produces no physical presentation, so the harness makes no claim about display accuracy, A/V timing or sustained player throughput.

## Sampled memory criteria

After three warmup cycles per mode, the harness compares the median drained memory from the latter half of measured cycles with the earlier half. Default permitted growth is 128 MiB for sampled process resident memory and 64 MiB for sampled active MLX memory. Override these with `--rss-growth-mib` and `--active-growth-mib`; changed tolerances must accompany the report. These are explicit regression thresholds, not hardware guarantees or proof that every transient allocation was sampled.

The effective MLX cache limit must match the runtime policy. Actual cache bytes are reported separately and may temporarily exceed that limit because MLX reclaims cached allocations on a subsequent allocation. Cache counters, model payload credits, frame reservations and process resident memory describe different ownership layers and must not be added together or treated as equivalent hard bounds.

The default 160×96 processing shape is a measured M3 development workload. Other shapes, source resolutions and M5 hardware require their own runs. The runner rejects dimensions above the configured processing admission limit instead of attempting unbounded allocations. Passing a small development shape does not establish full-resolution neural playback capacity.

## M3 evidence and issue 6 acceptance

The [compact evidence](evidence/m3-frame-lifecycle-stress.json) records a 24-cycle run on Apple M3, 16 GiB, macOS 26.5, with 320×192 PQ/HLG source frames and 160×96 neural processing. It completed in 21.82 seconds. This was a development build: the source tree was modified relative to its recorded base revision; the executable and exact source manifest remained unchanged during measurement. The report identifies source, model, MLX kernel and executable hashes. The runner also writes `summary.json` for future runs; raw frame measurements remain in the local `stress.json`.

| Measurement | Original | Neural Rendering |
|---|---:|---:|
| Cycles / completed / cancelled | 12 / 48 / 12 | 12 / 48 / 12 |
| Redraw identity checks | 384 | 384 |
| Peak frame slots / reserved bytes | 3 / 8,665,536 | 3 / 8,665,536 |
| Maximum synchronous submission | 29.8 µs | 32.9 µs |
| Maximum asynchronous reset-to-drained time | 2.29 ms | 224.36 ms |
| Sampled held process resident peak | 52,723,712 bytes | 394,657,792 bytes |
| MLX reported peak active | 1,474,560 bytes | 682,825,818 bytes |
| Drained active MLX memory | 0 bytes | 768 bytes |
| Warm drained RSS median growth | +144 KiB | −864 KiB |
| Warm drained active MLX growth | 0 bytes | 0 bytes |

Every cycle returned frame slots, frame reservations, model count and model payload credits to zero after the relevant consumer and session completed. The neural cache reached 274,793,010 bytes, above the 268,435,456-byte cache policy; this is consistent with the documented next-allocation reclamation behavior and is not counted as a hard-cap result.

The exact [issue 6](https://github.com/ScriptType/metal-dlss-mac-video/issues/6) criteria map to this evidence as follows:

| Acceptance criterion | Evidence and boundary |
|---|---|
| Seeking or source replacement cannot present obsolete output | [Generation tests](../packages/FrameEngine/Tests/FrameSessionTests.swift) reject queued/in-flight stale output. Every stress cycle cancels an admitted producer operation, rejects its old generation, then receives only the replacement source/generation. Renderer-side generation checks remain mandatory for old leases that intentionally survive resets; this offscreen run does not measure scanout. |
| Repeated presentation reuses output; a missed deadline does not reset valid history | Scheduler tests plus 768 real-path redraw identity checks. Processing/reset counters remain unchanged across redraws and expired deadlines; source replacement advances the reset count exactly once. |
| Responsive execution with bounded queued work and GPU ownership through consumers | Synchronous admission remained below 33 µs in this run. Three slots apply backpressure even for externally held output. A real Metal consumer retains those leases across close; all reservations release after command completion. Full generation drain and model-credit recovery occur before each following cycle. |

These results satisfy the shared-runner lifecycle checks at the recorded M3 workload. Full-resolution allocation behavior, M5 measurements, physical presentation and broader UI/display lifecycle acceptance retain their separate workload and hardware gates. They do not follow from this bounded run.
