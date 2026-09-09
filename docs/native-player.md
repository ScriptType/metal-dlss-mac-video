# Native player application

`HDRPlayer` hosts the patched mpv `gpu-next`/macvk renderer in an AppKit `NSView`. A separate, 196-point `WKWebView` contains locally bundled Tailwind controls. Video and subtitles are rendered natively; the web view contains no video, canvas or neural inference path. mpv is provisional while the [core comparison](implementation-status.md) remains open.

`HDRPlayer` imports the C client header through `CMpv` and loads libmpv at runtime. The shared engine and MLX enter the process through that library. The numeric `HDRHarness` is a separate executable so its static MLX runtime cannot coexist with mpv's engine in the player process. Diagnostic flags such as `--headless`, `--capture-dir`, `--report` and `--frames` launch the sibling harness with the original arguments.

## Build and bundle

```sh
bash scripts/build-mpv-adapter.sh
bash scripts/build-harness.sh
open "artifacts/HDR Player.app"
```

The build creates a local arm64 development bundle for macOS 26. It includes both executables and their controls resources, the shared engine, recursively resolved non-system dylibs, MoltenVK and its explicit Vulkan driver manifest, and the MLX Metal library. Native dependencies use relative loader paths. Every staged dependency is checked, nested code is signed ad hoc, and the app passes strict deep signature verification. This does not produce a notarized distribution.

An installed `models/neural-rendering/NeuralRendering.dlssmodel` is included by default. `MLXDLSS_NEURAL_RENDERING_PACKAGE` selects a different package; `BUNDLE_NEURAL_MODEL=0` omits it. The app looks for a model in that environment variable, its bundled `Resources/Models` directory, then the development checkout. Original playback remains available when no model is installed. `METAL_DLSS_MPV_LIBRARY` overrides the selected native library for diagnostics. `Resources/NativeRuntime.json` records staged source hashes, architecture and bundled model/driver locations.

## Controls and state

The file-only, main-frame bridge accepts:

```js
window.webkit.messageHandlers.player.postMessage({ command: 'seek', value: 12.5 });
window.addEventListener('player-state', event => render(event.detail));
```

State version 1 includes title/source, position/duration, pause, volume/mute, tracks, chapters, fullscreen, subtitle settings, processing state, native enhancement diagnostics and capability flags. Values come from mpv's polled properties; source frame rate is separate from completed processing measurements. Track names enter HTML text nodes. Navigation away from local files is rejected.

| Command | Value |
| --- | --- |
| `open` | Native file picker |
| `play`, `pause`, `togglePause` | None |
| `seek` | Absolute seconds, accurate seek |
| `frameStep` | `1` or `-1` |
| `volume`, `mute` | 0–100, boolean |
| `track` | `{ type: 'audio'\|'video'\|'sub', id: number\|'no'\|'auto' }` |
| `chapter` | Zero-based index |
| `enhancement` | Boolean; retained-session bypass |
| `strength`, `colorStrength` | 0–1 |
| `quality` | `{ width, height }`, each 16–8192, product at most 512 × 288 |
| `mode` | An entry in `processing.availableModes` |
| `compare` | `original`, `enhanced`, or omitted to toggle |
| `prepare` | `start` (also resume/reuse) or `cancel` |
| `cacheCapacityGiB` | 1–64, default 8 |
| `fullscreen` | Desired boolean |
| `subtitleBrightness`, `subtitleScale`, `subtitleDelay` | 0.1–1, 0.5–3, seconds |

The app starts enhancement in Adaptive mode. It exposes Live only when the running native session reports qualification. Processing size or effect changes replace the filter and reset qualification/history; bypass preserves the model session. Buffering, source preview, pending/completed counts and retained comparison come from `enhancement-state`. Comparison is available only for an actual retained pair while paused. The [adapter contract](mpv-adapter.md) defines the clock policy, qualification and exact-timestamp replacement behavior. PiP is not exposed by these controls.

Prepared mode uses the same filter-owned cache context as playback. It is offered for local MP4/M4V/MOV, the first video track and an installed model when the adapter reports support. Unsupported inputs and initialization failures carry an explicit capability reason; ordinary playback remains available. The preparation dialog provides Start/Resume, Cancel, a disk limit and committed coverage buttons for seeking. The default shared cache is `~/Library/Caches/HDRPlayer/Prepared` with an 8-GiB limit, 60-frame segments and 8 preroll frames. Preparation covers the complete video, avoiding approximate range bounds for variable frame rate input. `HDRPLAYER_CACHE_DIRECTORY` can select a diagnostic cache directory.

Request JSON is written on the playback worker immediately before context installation. Reconfiguration first removes and drains the old filter, then installs the new source/settings/capacity, preventing overlapping cache owners. Source or video-track changes leave Prepared mode. Progress coverage comes from `availableRanges`, not historical completed work. Display labels use immutable current-frame provenance, distinguishing cache output from original misses. See [Prepared playback](prepared-playback.md) for identity, atomic completion, cancellation and reuse semantics.

All libmpv commands, property access and destruction run on a worker. The waiting command queue is bounded at 64. New desired property values, filter configurations and seeks replace their waiting predecessors; relative frame/toggle actions retain order. AppKit can continue handling input during model setup and inference. The Settings dialog and Command-comma menu expose processing size and independent native subtitle brightness, scale and delay.

Preferences retain effect parameters, processing dimensions, volume/mute and subtitle settings. Live qualification is not restored from a preference. Open-file events received before launch are queued. Resize/fullscreen remain owned by the host window. System sleep pauses playback and wake resumes it only if it was previously playing. Quit first closes the worker while the ordinary AppKit loop remains active for native view detachment, then terminates after core destruction. The host retains the view throughout this interval.

## Functional check

```sh
python3 scripts/generate-player-fixture.py
HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-ui.json \
  .build/debug/HDRPlayer assets/test-clips/player-controls.mkv
```

The opt-in check uses isolated preferences and drives the shipped DOM. It verifies transport, a thousand volume-input events settling to the final value, two audio tracks, native subtitles, chapters, subtitle settings, exact paused seeking/frame stepping, resize/fullscreen, neural playback and retained comparison. Comparison checks rational PTS, generation and submission count. It requires float EDR configuration for enhanced output, records actual native state and reports failures before orderly shutdown. The fixture extends the generated PQ clip with a second audio track, subtitles and two chapters.

The separate Prepared dialog check uses the PQ MP4, with an isolated cache unless overridden:

```sh
HDRPLAYER_UI_SMOKE_KIND=prepared HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-prepared-ui.json \
  .build/debug/HDRPlayer assets/test-clips/hdr10-30.mp4
```

It exercises original misses, changing capacity after draining the old owner, progress, cancel/resume, committed-range seeking, cache provenance and reusing complete segments without more neural work.

This is a functional integration check. It does not establish sustained Live performance, calibrated display accuracy or physical presentation timing. Development measurements use the current M3; M5 measurements are separate future runs.
