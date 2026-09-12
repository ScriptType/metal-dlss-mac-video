# AppKit floating video diagnostic

`HDRPLAYER_FLOATING_VIDEO=1` adds **View → Floating Video (Diagnostic)** to HDRPlayer. This opt-in prototype moves the existing video host into an app-owned `NSPanel`, retaining the mpv child view and Metal layer. Playback commands continue to use the same player, audio output and subtitle composition. It does not create an exported stream or another renderer.

The prototype is a candidate for [issue #17](https://github.com/ScriptType/metal-dlss-mac-video/issues/17). Its AppKit controls and window behavior differ from Apple's system picture-in-picture. Product acceptance and native presentation qualification remain pending; ordinary playback does not expose the feature. The separate [sample-buffer PiP diagnostic](picture-in-picture.md) remains unavailable in ordinary playback. Setting both presentation opt-ins exits with code 2 before AppKit or the playback worker starts.

## Build and launch

In an already prepared checkout with the pinned submodules, runtime libraries and model available:

```sh
source scripts/env.sh
npm --prefix apps/controls ci
npm --prefix apps/controls run build
swift build --product HDRPlayer --jobs "$BUILD_JOBS" --disable-automatic-resolution
HDRPLAYER_FLOATING_VIDEO=1 .build/debug/HDRPlayer /absolute/path/video.mp4
```

This builds only the app shell. It still requires the patched libmpv and its shared engine at runtime, as described in [native player setup](native-player.md). `METAL_DLSS_MPV_LIBRARY` can select an existing compatible libmpv in another prepared checkout; its loader paths must resolve the matching engine. The app also needs its model in this checkout or an explicit `MLXDLSS_NEURAL_RENDERING_PACKAGE` path.

## Window and control behavior

Entry requires a settled, non-fullscreen main window and a valid layout. Four retained constraints attach the host to its main-window slot; entry replaces them with four constraints in the floating slot. Return reverses that move. The main slot displays a Return button while its video is floating.

The panel provides native Play/Pause, backward/forward five-second seek, and Return controls. Its buttons have accessibility labels. The existing native keyboard handler also accepts events from the floating window, preserving normal editing and button behavior for focused controls. Open, Settings and Full Screen restore and show the main window before performing their actions. Entering main-window fullscreen through the title bar also restores the video first. Entry while fullscreen or during a fullscreen transition is unavailable in this prototype.

Minimizing or closing the main window while video is floating leaves the panel and player alive. Explicit Return shows and deminiaturizes the main window. Closing the floating panel returns the host without showing or deminiaturizing the main window; Open, Settings or opening a file from Finder brings it back afterward. Dock reopening raises an active floating panel or restores the main window when video is home. Closing the main window once video is home terminates playback.

Quit disables floating controls and retains the host and panel while the native worker shuts down asynchronously. After mpv detaches its child, the host returns home and the panel is released. The ordinary AppKit loop stays active throughout native destruction.

## Evidence and qualification

`floatingVideo` diagnostic state records actual host, child, layer and window identities, active constraints, window bounds, screen, backing scale, visibility and occlusion. Display metadata comes from the window currently containing the video. These observations do not establish compositor presentation or physical HDR/A/V correctness; the corresponding qualification fields remain false.

The coordinated native smoke uses a 60-second PQ clip:

```sh
source scripts/env.sh
python3 scripts/test-player-lifecycle-playback.py \
  --scenario floating-video \
  --output artifacts/floating-video-run-1
```

Use a fresh output directory. The scenario exercises actual menu/button target-action dispatch and window methods, verifies retained objects and exact paused timestamps across entry/resize/return, checks transport and restoration, and inspects worker teardown after process exit. Programmatic dispatch does not prove physical mouse or keyboard delivery. The smoke requires the prepared native runtime and model and must run without concurrent GPU workloads.

Paused checks track the exact rational timestamp, current and displayed generations, accepted/emitted filter counters (`submitted-frames` and `completed-frames`), and pending count. `completed-frames` counts downstream emissions, not GPU completion. Initial setup and paused seeks require zero pending frames. Ordinary Pause after playback may retain up to three accepted frames awaiting emission, matching the filter's slot bound, provided no seek preview is pending and comparison is ready. The full identity and counters must remain unchanged across three consecutive comparisons while paused. Later window moves must preserve that same identity, including its pending count.

For an observed run, `HDRPLAYER_UI_SMOKE_WINDOW_OBSERVATIONS` names an observer-written JSON file. Before each timestamped native menu or button action, the smoke waits up to five seconds for a fresh observation of that exact window in the current process. Without this environment variable, the usual smoke proceeds unchanged. The observer atomically replaces the file only after validating session, display and resource conditions and querying positive on-screen windows for the bound player PID. Its schema is:

```json
{"version":1,"targetPID":123,"queryStartUptime":100.1,"queryEndUptime":100.2,"windows":[{"windowID":456,"onScreen":true,"alpha":1,"bounds":{"X":0,"Y":0,"Width":640,"Height":416}}]}
```

Both clocks use `NSProcessInfo.systemUptime`. The query must start after the action's wait begins, end no earlier than its start, and be complete and at most two seconds old when accepted. The matching window must be on-screen with alpha 1 and finite, positive bounds. Each accepted observation is recorded in a `windowObservation` snapshot, together with `waitStartedUptime`, before the original action request timestamp. This provides independently reviewable prior-window evidence; it does not qualify uninterrupted visibility, compositor presentation or physical input. Earlier untimestamped DOM setup remains outside this handshake.

### Fullscreen while floating

Set `HDRPLAYER_FLOATING_FULLSCREEN_DIAGNOSTIC=1` for a separate `--scenario floating-video` run with a fresh output directory. It holds the existing fixture at exact source time 20 seconds, with 160×96 Adaptive processing and subtitles disabled. It enters fullscreen through the native menu handler while floating, exits and re-enters floating, then repeats through `NSWindow.toggleFullScreen` to exercise delegate-driven restoration. A final floating entry retains the external runner's asynchronous teardown check. This diagnostic cannot be combined with the compositor capture opt-in.

The diagnostic records eight actual will/did callbacks. It checks the retained host/child/layer and paused identity, unchanged settings, four active home constraints, detached panel, disabled floating entry during transitions/fullscreen, and restored entry after exit. Seven actions require fresh main-window observation receipts when the external observer is configured. Setup and all transitions share a 90-second deadline; each fullscreen transition has a 15-second deadline. The menu route uses the same handler as native F, but this test does not deliver a physical key or titlebar click, switch desktops, or exercise another application's fullscreen Space.

The [M3 fullscreen run](evidence/m3-appkit-floating-fullscreen.json), using source `0fffc80f7471c8f4539ea844b1e6b5058b5865e7`, passes all 34 native checks and five external lifecycle checks. Both routes produce their ordered will-enter, did-enter, will-exit and did-exit callbacks. The exact paused identity remains `20000000/1000000`, generation 3, with one accepted input, one downstream emission and zero pending frames. Floating entry is unavailable during transitions and fullscreen, then available after each exit. Both restorations retain the expected objects and settings; final floating teardown verifies ordered detachment and worker destruction.

All seven actions have independently matched prior-window witnesses and consumed receipts. The evidence retains 40 native snapshots, 106 lifecycle rows, 27 OS observations and 23 published window records. The maximum sampled query-end gap is 441.183 ms; peak observed process-tree RSS is 828,276,736 bytes, excluding unattributed GPU/XPC allocations. The app exits cleanly without forced cleanup, with all frozen input pins unchanged. The isolated shell build and five focused CPU tests for action-window routing also pass. This run adds no compositor, physical input, HDR/A/V, desktop-switch or cross-application Space qualification.

[PR CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34694304501) and [branch CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34694302429) pass for the fullscreen source. Each compiles both changed Swift files and records 99 Python passes, 35 Swift passes, five explicit skips and a successful C API consumer. The PR also passes 92 Erika CPU tests, two parser tests and the native demo build; its tested merge tree equals the source tree. Hosted CI does not repeat this native fullscreen run.

### Coordinated compositor comparison

The additional `HDRPLAYER_FLOATING_CAPTURE_DIRECTORY` opt-in selects a three-stage capture protocol instead of the transport scenario. It requires a new absolute directory and an external coordinator. The player holds exact source time four seconds at 160×96 Adaptive processing, with subtitle track 1 selected, brightness/scale 1 and delay 0. The existing PQ fixture has a static positioned caption from three through six seconds. Main, floating and returned windows must each provide an actual 800×480-point video viewport, matching child/layer/backing geometry and the same drained frame identity.

Each stage publishes an immutable `<phase>-reference.json` and an atomically updated `<phase>-live.json`. The reference contains the session UUID, phase and sequence, PID, window ID, exact frame identity, subtitle/processing settings, measured window/video rectangles, display/backing information and deadlines. An external `<phase>-complete.json` acknowledgement must match that binding and the SHA-256 of the reference bytes, and set `captured` to true. The coordinator must publish complete acknowledgement bytes atomically without replacing existing evidence. The player rechecks identity and geometry before publishing `<phase>-after.json` and advancing. Each phase has a 30-second deadline; setup and all phases share a 105-second overall deadline. A final uncaptured floating entry retains the external runner's asynchronous teardown check.

Use the unchanged [ScreenCaptureKit helper](hdr-compositor-capture.md) built from this checkout to target its pinned `.build/debug/HDRPlayer`; retain an identical executable archive. The helper's workspace allowlist comes from its compile-time source path. Capture only the explicit PID/window, preserving raw pixels, actual ICC metadata and the caller reference. Derive equal-sized video ROIs from measured coordinates and backing scale without resampling. An acknowledgement records successful capture and unchanged held state; pixel comparison, physical HDR, scanout and A/V synchronization require separate evidence.

The [M3 compositor capture](evidence/m3-appkit-floating-compositor.json), using source `0cc7bbd58ed6c6156e505a802a99b16106579829`, completes all three stages with 23 native checks, five external lifecycle checks and three independently witnessed native actions. The exact held identity is `4000000/1000000`, generation 4, with two accepted inputs, one downstream emission and zero pending frames. Subtitle track 1 remains selected with unchanged settings. The process exits cleanly, without forced cleanup or changed input pins. Eight focused CPU protocol tests pass before launch.

Each captured video viewport is 1600×960 pixels at backing scale 2. Recorded geometry gives ROIs `(0,64,1600,960)` for main and returned windows, and `(0,48,1600,960)` for floating. All three 12,288,000-byte RGBA binary16 regions have SHA-256 `1b4fc61c7a7eb5ae83105be6ca8afe676e9315b799a34d878e76cf1ab83e0bf0`: every pair has zero differing bytes and pixels across all 1,536,000 pixels. This comparison includes extended-range and alpha values and performs no resampling or transfer conversion. It establishes equality of this captured, subtitle-enabled frame across the window moves.

The actual ICC attachment is identical in all captures. A separate comparison in its supported relative XYZ D50 domain also reports zero differences, but includes only 69,569 jointly opaque, finite, in-range pixels and excludes 1,466,431 pixels per pair. The complete encoded-byte comparison above covers those exclusions. Per-capture component statistics include window chrome; they are not viewport-only statistics or physical luminance measurements.

The coordinator retains 32 OS observations and bound before/after receipts for every stage. Only the main capture helper remains alive long enough to appear in periodic process sampling; the other two finish between samples and retain their owned process handles, successful exits and scoped capture reports. These observations do not establish continuous physical visibility, scanout, calibrated HDR, subtitle correctness against an independent reference, or playback synchronization.

[PR CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34693404649) and [branch CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34693402934) pass for this compositor source. Each compiles the app and records 99 Python passes, 35 Swift passes, five explicit skips and a successful C API consumer. The PR also passes 92 Erika CPU tests, two parser tests and the native demo build; its tested merge tree equals the source tree. Hosted CI does not run the native compositor capture.

The isolated M3 shell build and controls syntax/build checks pass. Eleven synthetic cases exercise the lifecycle-log validator, an existing-output check verifies evidence preservation, and the conflicting-opt-in invocation exits with code 2 before AppKit startup. These are nonvisual checks; the lifecycle data in those eleven cases is synthetic.

The [preserved native attempt](evidence/m3-appkit-floating-pause-control.json) passed 24 checks before its original smoke timed out waiting for zero pending frames after ordinary Pause. Its recorded pause acknowledgement and stable pending count remain failed evidence under that original criterion. Retrospective review found prior-window observations for 6 of 7 native actions; the runner failed before reaching that observer gate. The pending-count amendment and optional observation handshake above apply prospectively to a new build and capture. They do not rescore the failed run or weaken its prior-window requirement.

The [amended M3 functional capture](evidence/m3-appkit-floating-functional.json), using source `6849071147913ba15f135d8b6fc79ee347165897`, passes all 45 native checks and five external lifecycle checks. It uses the 60-second 320×192 PQ fixture at 160×96 Adaptive processing. Entry, resize, exact ±5-second seeks, playback with the main window minimized, ordinary Pause, explicit Return, main close, nonactivating panel close and asynchronous quit pass. The paused identity remains `20433000/1000000`, generation 6, with 19 accepted inputs, 17 downstream emissions and one pending frame through the later window operations.

All 12 timestamped native actions have both a matching consumed observation receipt and an independently checked prior-window witness. The evidence retains 66 DOM snapshots, 139 lifecycle rows, 44 OS observations and 38 published window records. The maximum sampled query gap is 450.222 ms and observed process-tree RSS peaks at 695,566,336 bytes; these bounds exclude unattributed GPU/XPC allocations. The process exits cleanly without forced cleanup, and all frozen runtime and prior-evidence pins remain unchanged. The updated isolated shell build and 11 CPU controls for the observer's receipt audit also pass.

The same executable separately passes the existing ordinary-controls regression with floating video and PiP disabled: 23 native checks and four external lifecycle checks, including audio/subtitle selection, exact seeking, fullscreen, enhancement and retained-frame comparison. All 20 DOM snapshots and 67 lifecycle records contain no floating state or events. Its 22 OS samples record a maximum query gap of 574.616 ms and peak process-tree RSS of 794,886,144 bytes. The process exits cleanly, with unchanged pins and no forced cleanup. This scenario has no pre-action observation handshake and does not qualify physical input delivery.

[PR CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34692199487) and [branch CI](https://github.com/ScriptType/metal-dlss-mac-video/actions/runs/34692197615) pass for the measured source. Each harness records 99 Python passes, 35 Swift passes, five explicit fixture/Metal/model skips and a successful C API consumer. The PR also passes 92 Erika CPU tests, two schedule-parser tests and the native demo build. The tested PR merge tree equals the source tree; these hosted checks do not repeat the native window captures.

Acceptance still requires representative HDR playback with a visible, uncovered panel, physical HDR and synchronization, ordinary input delivery, and Space/display transitions. The bounded same-frame compositor comparison, minimize/restore and ordinary-controls checks above pass. One captured subtitle-enabled frame does not establish broader color/subtitle correctness or physical behavior.
