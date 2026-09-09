# Roadmap acceptance status

The requirements in [issue 1](https://github.com/ScriptType/metal-dlss-mac-video/issues/1) and the [original plan](../mac-hdr-player-plan.md) remain authoritative. Implementation status does not close an issue or establish unmeasured acceptance results.

| Requirement | Current evidence | Remaining acceptance work |
|---|---|---|
| #2 Decoder planes and linear HDR | Closed: published NV12/P010 CoreVideo/Metal import; rational timing, geometry, retained owners and colour metadata; independent SDR/PQ/HLG numeric/chroma tests | Broader source coverage remains part of final playback acceptance |
| #3 Float output/native EDR | RGBA16F nits, native extended-linear P3 layer; exact 10,000-nit original test; SDR48/PQ60/HLG120 offscreen and PQ/HLG onscreen runs; reported 16× EDR | Physical display/colour accuracy and display migration qualification |
| #4 Neural HDR reconstruction | Closed: CPU/GPU BT.2020 codec tests; three real model frames; identity error under 0.0001 nit; exact original-object zero-strength bypass; four diagnostic views share one timestamp | Temporal visual acceptance on representative content and integrated player controls remain separate gates |
| #5 Shared C API | Plain C consumer validates actual HDR GPU output, rational PTS, retained producer ownership, redraw and leases surviving teardown | Exercise all adapter-owned resource paths as integration completes |
| #6 Async/history lifecycle | Bounded frame admission and output leases; lifecycle/GPU tests; generation-safe output, redraw and deadline history; process-wide model-count/payload/shape admission and MLX cache policy | Sustained end-to-end transient allocation and cancellation stress at intended workloads |
| #7 Completed-work instrumentation | Repeatable native decoder/engine benchmark; actual import/pack GPU times, separate completed stage wall time, process/MLX memory samples, C presentation/drop/seek/energy hooks | Sustained adapter runs, power/energy collection, full source/processing/display/revision provenance |
| #8 M5 optimization | Explicit processing dimensions affect neural execution; instrumentation ready | M5 Max access and matched measurements; retain only justified optimizations |
| #9 mpv adapter | Published async filter/native embedding; float VideoToolbox/libplacebo import; actual PQ/HLG neural and lifecycle runs; generation/clock policy | Longer controlled runs and completed adapter acceptance audit |
| #10 Erika adapter | Published async shared-engine wrapper and native float Metal presentation; 35 tests; actual SDR/PQ/HLG and neural seek/drain runs with limitations recorded | Completed candidate acceptance audit; matched comparison is separate |
| #11 Core comparison | mpv remains provisional; no evidence activates replacement | Matched alternating sustained M5 results, playback/quality checks and final decision |
| #12 Playback modes/clock | Published shared-clock Adaptive policy; controlled M3 run max sampled A/V offset 9.33 ms; 56.97-ms original seek preview and same-PTS enhanced replacement; six retained-pair toggles; Live correctly rejected | Longer/VFR/24/60-fps runs and a measured source-rate Live configuration; physical scanout is separate from renderer-current observations |
| #13 Persistent HDR cache | Eleven focused cache tests; float round trip, corruption/interruption handling, atomic publication, capacity/LRU/pinned leases; explicit HDR10 encode/decode evaluation | Natural-content qualification before adopting a production 10-bit policy; float remains current format |
| #14 Prepared mode | Real PQ cancellation/resume plus cache-backed shared session test; exact PTS across two segments; replay/reset reuse and original on missing ranges; asynchronous C job API | Selected-core cached playback/audio-clock integration, neural preroll/seams and sustained bounded run |
| #15 Application controls | Native mpv/WK bridge; actual DOM transport, timeline, tracks, chapters, volume/subtitle settings, frame step and fullscreen checks; policy/compare state mapping | Final bundled neural/compare walk-through and Prepared controls |
| #16 Lifecycle/accessibility | Native resize/fullscreen/shutdown checks; accessible labels/focus styles; persisted playback/subtitle/processing preferences; self-contained local runtime packaging | Sleep/wake/display transition, VoiceOver and preference-restoration validation; independent brightness under inference |
| #17 PiP | Deferred by its explicit processed-HDR capability gate | Demonstrate compatible enhanced/HDR PiP before enabling |
| #18 Dolby Vision | No profile support claimed | Profile assets, decoder metadata/reshaping evaluation and explicit supported/fallback table |
| #19 Direct Metal libplacebo | Activation condition has not been demonstrated | Activate only for measured material interop limitations that targeted fixes cannot resolve |
| #20 Custom playback core | Activation condition has not been demonstrated | Activate only if both candidate evaluations establish unmet requirements |

## Evidence and reproduction

`bash scripts/check.sh` covers the root Swift engine/cache/display tests, C consumer, Python extraction tests and generated fixtures. The MLX fork's `docs/native-hdr.md` documents its focused GPU/neural/SDR-export regression checks. [Presentation](hdr-presentation.md), [frame-engine](frame-engine.md) and [cache](hdr-cache.md) references contain commands and interpretation policies.

The complete root check passed 24 Swift tests, 25 Python extraction tests, the plain C real-GPU consumer, controls/assets and GPU/decode probes. Local ignored evidence includes `artifacts/implementation-checks-current.log`, `artifacts/hdr-display/`, `artifacts/hdr-engine-*.json`, `artifacts/hdr-cache-evaluation/`, and `artifacts/mpv-policy-pq-controlled-neural*.json`. [mpv](mpv-adapter.md), [Erika](erika-adapter.md) and [native player](native-player.md) documents record reproduction and measured limitations. Tiny M3 model runs prove pipeline wiring and measurement boundaries; they do not prove source-rate Live playback, sustained M5 throughput or temporal visual quality.

## Final baseline gates

Final acceptance still requires no unintended HDR clipping/gamut loss with correct PQ/HLG/display mapping; bypass before proxy quantization; no progressive A/V drift; source-rate warmed Live operation without backlog; exact seek generation/timestamp pairing; bounded queues/pools/cache/model residency; accepted temporal quality; and responsive controls through window/display transitions. The full source and interaction corpus remains as specified in the original plan. Missing, indirect or development-only evidence does not satisfy a broader gate.
