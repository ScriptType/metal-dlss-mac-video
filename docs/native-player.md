# Native player application

`HDRPlayer` hosts the patched mpv `gpu-next`/macvk renderer in an AppKit `NSView`. A separate, 196-point `WKWebView` contains locally bundled Tailwind controls. Video and subtitles are rendered natively; the web view contains no video, canvas or neural inference path. mpv is provisional while the [core comparison](implementation-status.md) remains open.

`HDRPlayer` imports the C client header through `CMpv` and loads libmpv at runtime. The shared engine and MLX enter the process through that library. The numeric `HDRHarness` is a separate executable so its static MLX runtime cannot coexist with mpv's engine in the player process. Diagnostic flags such as `--headless`, `--capture-dir`, `--report` and `--frames` launch the sibling harness with the original arguments.

## Build and bundle

```sh
bash scripts/build-harness.sh
open "artifacts/HDR Player.app"
```

The build installs the controls packages, builds the pinned libplacebo and the frame-engine mpv, and creates a local arm64 development bundle for macOS 26. The libplacebo and mpv builds are configured from scratch whenever a submodule pin, the build script or a Homebrew Cellar version changes, because a configured build caches versioned Cellar paths and pkg-config flags. It includes both executables and their controls resources, the shared engine, recursively resolved non-system dylibs, MoltenVK and its explicit Vulkan driver manifest, and the MLX Metal library. Native dependencies use relative loader paths. Every staged dependency is checked, nested code is signed ad hoc, and the app passes strict deep signature verification. This does not produce a notarized distribution.

An installed `models/neural-rendering/NeuralRendering.dlssmodel` is included by default. `MLXDLSS_NEURAL_RENDERING_PACKAGE` selects a different package; `BUNDLE_NEURAL_MODEL=0` omits it. The app looks for a model in that environment variable, its bundled `Resources/Models` directory, then the development checkout. Original playback remains available when no model is installed. `METAL_DLSS_MPV_LIBRARY` overrides the selected native library for diagnostics. `Resources/NativeRuntime.json` records staged source hashes, architecture, bundled model/driver locations, the root commit with a dirty flag, and the checked-out commit of each submodule, nested ones included.

The [current M3 ordinary-app regression](evidence/m3-demux-current-validation.json) passed all 23 controls and lifecycle checks in both the current bundle and a copy launched outside the checkout. With `HDRPLAYER_ENABLE_PIP` unset, PiP state was absent and its capability was false. The relocated app found its own model and runtime without overrides; the main-process loader log contained one shared engine, one libmpv, no harness and no non-system images outside the bundle. Both copies retained valid strict signatures and unchanged binaries after playback. This verifies the development artifact at `artifacts/HDR Player.app`; it does not establish notarized distribution, calibrated HDR or sustained physical A/V timing.

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
| `mode` | An entry in `processing.availableModes`. Ordinary playback offers only `prepared`. |
| `compare` | `original`, `enhanced`, or omitted to toggle |
| `prepare` | `start` (also resume/reuse) or `cancel` |
| `cacheCapacityGiB` | 1–64, default 8 |
| `fullscreen` | Desired boolean |
| `subtitleBrightness`, `subtitleScale`, `subtitleDelay` | 0.1–1, 0.5–3, seconds |

Dolby Vision uses the native renderer and disables neural/Prepared controls through `processing.enhancementAvailable` and a descriptive reason. Stream profile and compatibility metadata remain visible in track state. See [Dolby Vision paths](dolby-vision.md) for the profile-specific limits.

Prepared is the only enhancement mode in ordinary playback (#34). On the M3, warmed enhancement takes about 90 ms per frame at processing sizes up to 160 × 96, and 172 ms at p95 at 320 × 192. A 24 fps source leaves 41.7 ms per frame. In Adaptive mode, a 97.7-second HDR10+ clip needed 388.7 seconds of wall time. `processing.availableModes` is `["prepared"]` when Prepared is available for the open file and empty otherwise. The mode select lists only those entries. When Prepared is unavailable, `processing.unavailableReason` says why and the enhancement switch is disabled. Switching enhancement on creates the Prepared context for the open file. Switching it off only bypasses the filter, so a running preparation continues. The Prepare button appears once a context exists.

Prepared runs the filter with `policy=direct`, so a late frame never pauses the audio and video clocks. mpv may drop that frame instead. Ranges that are not prepared yet play the original at source rate. The default processing size stays 32 × 24, because #34 ties a new default to the owner's visual check in #3, which has not happened.

`HDRPLAYER_DEVELOPER_MODES=1`, read once at launch, restores Live and Adaptive. In developer mode the app starts enhancement in Adaptive mode. It exposes Live only when the running native session reports qualification. Processing size or effect changes replace the filter and reset qualification/history; bypass preserves the model session. Buffering, source preview, pending/completed counts and retained comparison come from `enhancement-state`. Comparison is available only for an actual retained pair while paused. The [adapter contract](mpv-adapter.md) defines the clock policy, qualification and exact-timestamp replacement behavior. PiP is not exposed by these controls.

Prepared mode uses the same filter-owned cache context as playback. It is offered for local MP4/M4V/MOV/Matroska, the first video track and an installed model when the adapter reports support. Unsupported inputs and initialization failures carry an explicit capability reason; ordinary playback remains available. The preparation dialog provides Start/Resume, Cancel, a disk limit and committed coverage buttons for seeking. The default shared cache is `~/Library/Caches/HDRPlayer/Prepared` with an 8-GiB limit, 60-frame segments and 8 preroll frames. Preparation covers the complete video, avoiding approximate range bounds for variable frame rate input. `HDRPLAYER_CACHE_DIRECTORY` can select a diagnostic cache directory.

Request JSON is written on the playback worker immediately before context installation. Reconfiguration first removes and drains the old filter, then installs the new source/settings/capacity, preventing overlapping cache owners. In ordinary mode, opening a file removes the old Prepared filter before `loadfile`. With enhancement on, the app installs a filter for the new file once mpv reports its tracks. Selecting a video track other than 1 removes the filter, so the original plays, and returning to track 1 installs it again. A Prepared context that fails, or an install that leaves no context, removes the filter until you open another file or change a processing setting. Other mpv errors are shown but leave a running preparation alone. In developer mode, a source change or a video track other than 1 leaves Prepared for Adaptive. Progress coverage comes from `availableRanges`, not historical completed work. Display labels use immutable current-frame provenance, distinguishing cache output from original misses. See [Prepared playback](prepared-playback.md) for identity, atomic completion, cancellation and reuse semantics.

All libmpv commands, property access and destruction run on a worker. The waiting command queue is bounded at 64. New desired property values, filter configurations and seeks replace their waiting predecessors; relative frame/toggle actions retain order. AppKit can continue handling input during model setup and inference. The Settings dialog and Command-comma menu expose processing size and independent native subtitle brightness, scale and delay.

Preferences retain effect parameters, processing dimensions, volume/mute, subtitle settings and cache capacity. Settings also work before opening media. Live qualification is not restored from a preference. Open-file events received before launch are queued. Resize/fullscreen remain owned by the host window. System sleep pauses playback and wake resumes it only if it was previously playing. Quit or Command-W first closes the worker while the ordinary AppKit loop remains active for native view detachment, then terminates after core destruction. The host retains the view throughout this interval.

Native menus provide Open (Command-O), Settings (Command-comma), Close (Command-W), Play/Pause (Command-P), frame stepping (Command-left/right bracket), Mute (Command-M), and fullscreen (Control-Command-F). When the native video has focus, Space, arrows, F, M and comma/period handle playback directly. Left/Right seek five seconds; Shift-Left/Right seek 60 seconds, consistently across the native video and WebKit background. Focused form controls retain their normal arrow-key behavior. WebKit receives keys while a control has focus, and Tab navigation includes form controls without changing the system keyboard preference. Dialogs expose their headings and labeled controls through the native accessibility tree; Escape closes them.

## Functional check

```sh
python3 scripts/generate-player-fixture.py
HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-ui.json \
  .build/debug/HDRPlayer assets/test-clips/player-controls.mkv
HDRPLAYER_DEVELOPER_MODES=1 HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-ui-developer.json \
  .build/debug/HDRPlayer assets/test-clips/player-controls.mkv
```

The opt-in check uses isolated preferences and drives the shipped DOM. It verifies transport, a thousand volume-input events settling to the final value, two audio tracks, native subtitles, chapters, subtitle settings, exact paused seeking/frame stepping and resize/fullscreen. The ordinary run then checks that the state and the mode select offer only Prepared and that the enhancement switch turns Prepared on. The developer run switches to Adaptive and checks neural playback and retained comparison. [`scripts/test-player-lifecycle-playback.py`](player-lifecycle-diagnostics.md) runs both. Comparison checks rational PTS, generation and submission count. It requires float EDR configuration for enhanced output, records actual native state and reports failures before orderly shutdown. The fixture extends the generated PQ clip with a second audio track, subtitles and two chapters.

The separate Prepared dialog check uses the PQ MP4, with an isolated cache unless overridden:

```sh
HDRPLAYER_UI_SMOKE_KIND=prepared HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-prepared-ui.json \
  .build/debug/HDRPlayer assets/test-clips/hdr10-30.mp4
```

It exercises original misses, changing capacity after draining the old owner, progress, cancel/resume, committed-range seeking, cache provenance and reusing complete segments without more neural work.

The source-rate check plays a file that is not prepared yet while preparation runs. It needs the neural model. Set `MLXDLSS_NEURAL_RENDERING_PACKAGE` when the model is not installed in this checkout:

```sh
MLXDLSS_NEURAL_RENDERING_PACKAGE=/path/to/NeuralRendering.dlssmodel \
  HDRPLAYER_UI_SMOKE_KIND=prepared-playback HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-prepared-playback.json \
  .build/debug/HDRPlayer assets/test-clips/playback/pq-30-60s.mkv
```

It runs in ordinary mode on the 60-second, 30 fps PQ clip. It starts playback with enhancement off, then samples the state every 100 ms while it switches enhancement on, waits for the Prepared context, starts preparation and keeps playing for 12 more seconds. It fails if the clocks buffer for enhancement or `buffer-count` rises at any point, including the moment enhancement is switched on. It also fails if position advances outside 0.97 to 1.03 seconds per wall second, over the whole window or over the 12 seconds of preparation, or if the job leaves the preparing state. Then it switches enhancement off, checks that preparation continues, switches it back on while playing and fails on any clock hold. The report records frame drops and the worst lag of video behind wall time without asserting them.

The mpv filter emits no original-first preview under `policy=direct`, so installing the Prepared filter during playback holds neither clock. Adaptive keeps its preview. On the M3 at 32 × 24, five runs with a build running beside them (load average 5 to 8) advanced 0.994 to 1.003 seconds of video per wall second over the whole window, and 0.993 to 1.006 while preparing. `buffer-count` stayed at 0 through switching enhancement on, preparing and switching it off and on again. Runs dropped 0 to 7 frames, and the worst video lag was 0.15 to 0.31 seconds. Earlier runs under heavier GPU load dropped up to 99 frames and lagged up to 1.5 seconds before catching up, with the clocks still running.

The source-change check opens a second file through the app's open-file handler, then turns the video track off and back on:

```sh
HDRPLAYER_UI_SMOKE_KIND=prepared-follows-source HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-prepared-follows-source.json \
  .build/debug/HDRPlayer assets/test-clips/playback/pq-30-30s.mkv assets/test-clips/playback/pq-30-30s.mp4
```

It checks that Prepared is installed for the second file, that leaving video track 1 turns enhancement off, and that returning to track 1 installs Prepared again. Both clips have one video track, so the check cannot show that Prepared is removed before a switch to a second video track.

Preference restoration uses two separate processes and an isolated defaults suite. The second invocation preserves the suite written by the first:

```sh
HDRPLAYER_UI_SMOKE_KIND=preferences-write HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-preferences-write.json \
  .build/debug/HDRPlayer
HDRPLAYER_UI_SMOKE_KIND=preferences-read HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES=1 \
  HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-preferences-read.json .build/debug/HDRPlayer
```

Both phases verify volume/mute, processing dimensions, subtitle brightness/scale/delay and cache capacity through the actual native state with no source loaded. These checks do not change the normal player preferences.

For an external accessibility inspection, foreground a running player and pass its process ID:

```sh
osascript scripts/read-player-accessibility.applescript PLAYER_PID
```

The script reads the AppKit/WebKit tree without changing accessibility settings. The automation client needs macOS Accessibility permission. On the current M3, external inspection verified labeled video, transport, seek, volume, track, processing and subtitle controls with correct disabled states for an empty player. Actual keyboard events verified Command-comma, Tab through subtitle settings, Escape, return to Open, and Command-W with clean process exit. The two-process preference check also passed. Fullscreen/resize and responsive controls during inference are covered by the media check above. VoiceOver speech, a physical sleep/wake cycle and moving playback to another physical display remain unverified; this machine has one built-in display.

The [Shift-arrow regression](evidence/m3-player-keyboard-seek.json) aligns web seeking with the native 60-second shortcut. The rebuilt app passes all 23 existing controls/lifecycle checks, and an isolated WebKit instance loading the packaged controls passes 22 synthetic DOM-event cases for seek increments, bounds and form/modifier guards. External mouse/keyboard automation did not establish the required focus routes, so actual native/WebKit focus and seek delivery remain unqualified by this check. All launched players exit cleanly and their complete preferences are restored.

The opt-in [lifecycle recorder and VoiceOver capability probe](player-lifecycle-diagnostics.md) capture real system events and native transport state without changing OS settings. Eight CPU pause-intent regression cases and the recorder format/bounds/flush check pass; they do not qualify physical sleep or speech.

This is a functional integration check. It does not establish sustained Live performance, calibrated display accuracy or physical presentation timing. Development measurements use the current M3; M5 measurements are separate future runs.

## Native subtitle brightness regression

Subtitle brightness sends an opaque six-digit RGB colour to mpv. Its eight-digit syntax is `#AARRGGBB`; a CSS-style `#RRGGBBAA` value changed opacity and the blue channel instead of producing neutral gray. The native DOM check now requires brightness 0.6 to read back as `#FF999999`.

```sh
uv run --frozen scripts/test-mpv-subtitle-brightness.py --strength-sweep \
  --output artifacts/subtitle-brightness
```

The [M3 pixel check](evidence/m3-subtitle-brightness.json) captures hidden, white, half-gray, quarter-gray and repeated subtitle states on one paused neural frame at exact source PTS 767/1000. All six captures preserve its generation and inference submission count. Only 3,348 pixels in the lower subtitle region change; the upper video region and repeated captures are bit-identical. Every RGB channel decreases monotonically with the gray setting. The native app's separate DOM check also passed the opaque-gray assertion and exited cleanly.

The strength sweep keeps source PTS unchanged while rebuilding enhancement at strengths 1, 0.5 and 0.25. All 503 fully covered gray glyph pixels remain bit-identical, while the two lower strengths change 409,689 and 409,687 video pixels. White/black captures identify full coverage, allowing the measured two-code black conversion floor; the gray comparison avoids saturated white and excludes background-dependent antialiased edges.

Captures are 16-bit sRGB/BT.709 PNGs from `gpu-next`, with dithering and dynamic peak detection disabled for deterministic comparison. They verify native composition and control mapping, not physical HDR luminance or WebKit overlay brightness. The evidence retains both product failures found by this check: a screenshot query before the oldest queued frame after a retained seek, fixed by clamping to that frame's PTS, and the incorrect eight-digit colour encoding. It also preserves the initial coverage-mask failure before accounting for the native encoded black floor.
