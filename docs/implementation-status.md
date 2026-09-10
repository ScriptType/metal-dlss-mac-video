# Roadmap acceptance status

The requirements in [issue 1](https://github.com/ScriptType/metal-dlss-mac-video/issues/1) and the [original plan](../mac-hdr-player-plan.md) remain authoritative. Implementation status does not close an issue or establish unmeasured acceptance results.

| Requirement | Current evidence | Remaining acceptance work |
|---|---|---|
| #2 Decoder planes and linear HDR | Closed: published NV12/P010 CoreVideo/Metal import; rational timing, geometry, retained owners and colour metadata; independent SDR/PQ/HLG numeric/chroma tests | Broader source coverage remains part of final playback acceptance |
| #3 Float output/native EDR | RGBA16F nits, native extended-linear P3 layer; exact 10,000-nit original test; SDR48/PQ60/HLG120 offscreen and PQ/HLG onscreen runs; reported 16× EDR | Physical display/colour accuracy and display migration qualification |
| #4 Neural HDR reconstruction | Closed: CPU/GPU BT.2020 codec tests; three real model frames; identity error under 0.0001 nit; exact original-object zero-strength bypass; four diagnostic views share one timestamp | Temporal visual acceptance on representative content and integrated player controls remain separate gates |
| #5 Shared C API | Closed: plain C consumer validates actual HDR GPU output, rational PTS, retained producer ownership, redraw and leases surviving teardown | New Prepared/runtime extensions retain their own focused boundary checks |
| #6 Async/history lifecycle | Bounded frame admission and output leases; lifecycle/GPU tests; generation-safe output, redraw and deadline history; process-wide model-count/payload/shape admission and MLX cache policy | Sustained end-to-end transient allocation and cancellation stress at intended workloads |
| #7 Completed-work instrumentation | Closed: clean isolated revision: four 300-frame M3 runs at 32×24 and 160×96, 270 warmed samples each; identical repeated numeric references; completed GPU import/pack and wall stages, memory, shared adapter hooks and unavailable metrics | Broader playback/power qualification remains separate from instrumentation acceptance |
| #8 M5 optimization | Explicit processing dimensions affect neural execution; instrumentation ready | M5 Max access and matched measurements; retain only justified optimizations |
| #9 mpv adapter | Closed prototype: published async filter/native embedding; float import; actual PQ/HLG neural/lifecycle and controlled generation/clock runs | Longer/varied-source qualification remains #12; final comparison is #11 |
| #10 Erika adapter | Closed prototype: published shared-engine/native float presentation; 35 tests; actual SDR/PQ/HLG neural seek/drain runs and measured limitations | Matched comparison and final selection remain #11 |
| #11 Core comparison | mpv remains provisional; no evidence activates replacement | Matched alternating sustained M5 results, playback/quality checks and final decision |
| #12 Playback modes/clock | Shared-clock Adaptive, exact seek previews and retained comparison; 30-second SDR24/HLG60/PQ-VFR runs remained bounded with no progressive median drift | HLG60 and PQ-VFR briefly exceeded 20 ms (22/20.33 ms); verify timing fixes and qualify a source-rate Live setting; physical scanout is separate |
| #13 Persistent HDR cache | Closed: eleven cache tests; float round trip, corruption/interruption rejection, atomic publication, capacity/LRU/pinned leases; HDR10 encode/decode evaluation | Natural-content qualification before adopting a production 10-bit policy; float remains current format |
| #14 Prepared mode | Exact decoder timing inventories; real NR MP4/MKV/VFR preparation, cancellation and two-process reuse; original misses and same-PTS hits; Prepared DOM controls | Sustained synchronized playback across cached/original segment transitions and larger resource workloads |
| #15 Application controls | Closed on provisional mpv: actual DOM transport/tracks/chapters/settings/frame-step/fullscreen and same-PTS neural comparison; relocated bundled runtime passes | Final core decision remains #11; Prepared additions continue with #14 |
| #16 Lifecycle/accessibility | Native resize/fullscreen/shutdown, actual macOS accessibility tree and keyboard navigation; preferences restored across two app processes; bundled runtime | Physical sleep/wake/display transition, VoiceOver speech and calibrated independent subtitle brightness under inference |
| #17 PiP | Deferred by its explicit processed-HDR capability gate | Demonstrate compatible enhanced/HDR PiP before enabling |
| #18 Dolby Vision | Real FATE Profile 8.4 native and explicit HLG-base playback; zero neural submissions; UI capability gate and invalid-metadata rejection; documented profile/fallback table | Calibrated colour and additional representative profiles; neural DV input remains unavailable |
| #19 Direct Metal libplacebo | Activation condition has not been demonstrated | Activate only for measured material interop limitations that targeted fixes cannot resolve |
| #20 Custom playback core | Activation condition has not been demonstrated | Activate only if both candidate evaluations establish unmet requirements |

## Evidence and reproduction

`bash scripts/check.sh` covers the root Swift engine/cache/display tests, C consumer, Python extraction tests and generated fixtures. The MLX fork's `docs/native-hdr.md` documents its focused GPU/neural/SDR-export regression checks. [Presentation](hdr-presentation.md), [frame-engine](frame-engine.md) and [cache](hdr-cache.md) references contain commands and interpretation policies.

The complete root check passed 24 Swift tests, 25 Python extraction tests, the plain C real-GPU consumer, controls/assets and GPU/decode probes. Local ignored evidence includes `artifacts/implementation-checks-current.log`, `artifacts/hdr-display/`, `artifacts/hdr-engine-*.json`, `artifacts/hdr-cache-evaluation/`, and `artifacts/mpv-policy-pq-controlled-neural*.json`. [mpv](mpv-adapter.md), [Erika](erika-adapter.md) and [native player](native-player.md) documents record reproduction and measured limitations. Tiny M3 model runs prove pipeline wiring and measurement boundaries; they do not prove source-rate Live playback, sustained M5 throughput or temporal visual quality.

## Final baseline gates

Final acceptance still requires no unintended HDR clipping/gamut loss with correct PQ/HLG/display mapping; bypass before proxy quantization; no progressive A/V drift; source-rate warmed Live operation without backlog; exact seek generation/timestamp pairing; bounded queues/pools/cache/model residency; accepted temporal quality; and responsive controls through window/display transitions. The full source and interaction corpus remains as specified in the original plan. Missing, indirect or development-only evidence does not satisfy a broader gate.
