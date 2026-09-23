# Implementation status

This page states what is true on `main` today, one line per issue. The [roadmap issue](https://github.com/ScriptType/metal-dlss-mac-video/issues/1) and the [v1.0 (M3) milestone](https://github.com/ScriptType/metal-dlss-mac-video/milestone/6) are authoritative. An issue closes only when its own "Done when" list is met, not because this page says so.

All measurements were taken on the development MacBook Pro (M3, 16 GB). Nothing has been measured on the M5 Max.

## v1.0 (M3) milestone

| Issue | True today |
|---|---|
| [#34](https://github.com/ScriptType/metal-dlss-mac-video/issues/34) Playback-mode policy | Ordinary playback offers only Prepared, which plays unprepared ranges as the original at source rate (`policy=direct`). `HDRPLAYER_DEVELOPER_MODES=1` restores Live and Adaptive. |
| [#35](https://github.com/ScriptType/metal-dlss-mac-video/issues/35) 10-bit HEVC Prepared cache | `HDRSegmentCache` stores Float32 RGBA (`packages/FrameEngine/Sources/HDRCache.swift`), about 33 MB per 1080p frame. The default 8 GiB capacity holds about 11 seconds of 1080p. |
| [#36](https://github.com/ScriptType/metal-dlss-mac-video/issues/36) Whole-file preparation with resume | Preparation reuses segments already in the cache. There is no whole-file queue, and preparation does not resume after a relaunch. Depends on #35. |
| [#37](https://github.com/ScriptType/metal-dlss-mac-video/issues/37) The ~90 ms enhancement floor | Warmed work p50 is 89 to 100 ms per frame at both 32×24 and 160×96 ([benchmarks](m3-benchmarks.md#clean-completed-work-reference)). Nobody has attributed the time outside optical flow. |
| [#38](https://github.com/ScriptType/metal-dlss-mac-video/issues/38) Remove system PiP | Done in [PR #48](https://github.com/ScriptType/metal-dlss-mac-video/pull/48). The player, its scripts and `tools/HDRPiPProbe` no longer contain the system PiP path. The optional `hdr_frame.h` exporter stays in the mpv fork because two color probes read frames through it. |
| [#17](https://github.com/ScriptType/metal-dlss-mac-video/issues/17) Floating video window | **View > Float Video** moves the playing video into an always-on-top panel and back without a reload (`apps/macos/Sources/FloatingVideoController.swift`). Every way out of the panel shows the main window with the video. `scripts/test-floating-video.py` checks the moves, both close orders, another app's full-screen Space and quitting while floating. Keys in the panel still need the [human check](human-checks.md#floating-video-17). |
| [#42](https://github.com/ScriptType/metal-dlss-mac-video/issues/42) Toolchain check and fresh build | `scripts/check.sh` runs the toolchain checks of `scripts/doctor.sh` first, and `doctor.sh` fails below 15 GiB free. `scripts/build-harness.sh` builds libplacebo, mpv and the app from the current tree and records the revisions in the bundle. |
| [#40](https://github.com/ScriptType/metal-dlss-mac-video/issues/40) Run logs out of `docs/evidence` | `scripts/audit-public-tree.py` fails when a tracked file in `docs/evidence` exceeds 256 KB. Raw run logs belong in `artifacts/`, which Git ignores. |
| [#41](https://github.com/ScriptType/metal-dlss-mac-video/issues/41) Drop rejected-optimization tests | [PR #46](https://github.com/ScriptType/metal-dlss-mac-video/pull/46) removed the erosion measurement tests from the MLX-DLSS fork and moved the pin. The pooling and erosion results stay as short entries in [benchmarks](m3-benchmarks.md#rejected-optimizations). |
| [#39](https://github.com/ScriptType/metal-dlss-mac-video/issues/39) EDR headroom on screen change | `windowDidChangeScreen` only records a lifecycle event (`apps/macos/Sources/main.swift`). Headroom is not re-read. Needs a human for the final check. |
| [#3](https://github.com/ScriptType/metal-dlss-mac-video/issues/3) HDR output on the built-in XDR | Float output keeps values above reference white, and zero strength returns the original ([colour audit](native-hdr-color-audit.md), [HDR10+ playback](apple-hdr-playback.md)). No settled screen capture exists, and nobody has looked at the output on an HDR display. |
| [#16](https://github.com/ScriptType/metal-dlss-mac-video/issues/16) Sleep/wake and VoiceOver | Enhancement strength leaves subtitle pixels unchanged ([evidence](evidence/m3-subtitle-brightness.json)). The accessibility tree and keyboard navigation pass automated checks ([native player](native-player.md)). Real sleep/wake and VoiceOver speech need a human. |

## After v1.0

| Issue | True today |
|---|---|
| [#8](https://github.com/ScriptType/metal-dlss-mac-video/issues/8) M5 Max measurements | Needs M5 Max hardware. On the M3, Live at 320×192 measures 341.478 ms native p95 against a 33.367 ms budget and is refused ([evidence](evidence/m3-minimum-live-window.json)). |
| [#33](https://github.com/ScriptType/metal-dlss-mac-video/issues/33) AirPods A/V offset | Deferred. Adaptive reaches 96 to 122 ms offset on AirPods. The fix attempts are on `wip/*` branches of the mpv fork and are not pinned. |

## Recently closed

| Issue | True today |
|---|---|
| [#11](https://github.com/ScriptType/metal-dlss-mac-video/issues/11) Playback core | mpv is selected. In the matched visible M3 run, mpv kept queue offsets within 1.333 ms, and Erika lagged video by 290 to 309 ms median ([comparison](adapter-comparison.md), [evidence](evidence/m3-adapter-comparison-visible.json)). The Erika adapter is frozen. |
| [#12](https://github.com/ScriptType/metal-dlss-mac-video/issues/12) Adaptive playback and seeking | Seeks never show a stale generation or a mismatched original/enhanced pair. A 97.7-second HDR10+ clip plays in 388.7 wall seconds with scheduled A/V offsets within 3.125 ms on the built-in speakers ([evidence](evidence/m3-natural-hdr-long-eof.json)). Live moved to #8, AirPods to #33 and the mode policy to #34. |
| [#31](https://github.com/ScriptType/metal-dlss-mac-video/issues/31) CoreAudio channel layout | Fixed in the mpv fork and pinned ([record](coreaudio-channel-layout.md)). |
| [#30](https://github.com/ScriptType/metal-dlss-mac-video/issues/30) Floating-window keys | Not reproducible with tracing. The untested case is part of the #17 human check. |
| [#19](https://github.com/ScriptType/metal-dlss-mac-video/issues/19) Direct Metal libplacebo | Not planned. No measured Vulkan/Metal interop cost exists. |
| [#20](https://github.com/ScriptType/metal-dlss-mac-video/issues/20) Custom playback core | Not planned. mpv runs the app and was selected in #11. |

## Closed earlier

These issues built the pipeline the player runs on. Each document records its commands and measured limits.

| Issue | Document |
|---|---|
| [#2](https://github.com/ScriptType/metal-dlss-mac-video/issues/2) NV12/P010 import to linear HDR, [#4](https://github.com/ScriptType/metal-dlss-mac-video/issues/4) neural HDR reconstruction | [Frame engine](frame-engine.md) |
| [#5](https://github.com/ScriptType/metal-dlss-mac-video/issues/5) shared C API, [#6](https://github.com/ScriptType/metal-dlss-mac-video/issues/6) async scheduling, [#7](https://github.com/ScriptType/metal-dlss-mac-video/issues/7) completed-work instrumentation | [Frame engine](frame-engine.md), [M3 benchmarks](m3-benchmarks.md) |
| [#9](https://github.com/ScriptType/metal-dlss-mac-video/issues/9) mpv adapter, [#10](https://github.com/ScriptType/metal-dlss-mac-video/issues/10) Erika adapter | [mpv adapter](mpv-adapter.md), [Erika adapter](erika-adapter.md) |
| [#13](https://github.com/ScriptType/metal-dlss-mac-video/issues/13) HDR segment cache, [#14](https://github.com/ScriptType/metal-dlss-mac-video/issues/14) Prepared playback | [Cache policy](hdr-cache.md), [Prepared playback](prepared-playback.md) |
| [#15](https://github.com/ScriptType/metal-dlss-mac-video/issues/15) native player and controls | [Native player](native-player.md) |
| [#18](https://github.com/ScriptType/metal-dlss-mac-video/issues/18) Dolby Vision profiles 5 and 8.4 | [Dolby Vision](dolby-vision.md) |

## Checks

`bash scripts/check.sh` runs the Python unit tests, the mpv Live-policy and audio-clock tests, the player lifecycle test, the controls build, the root Swift tests, the plain C frame API consumer, fixture generation, the GPU and decode probes and the public-tree audit. Commands for individual areas are in the linked documents.
