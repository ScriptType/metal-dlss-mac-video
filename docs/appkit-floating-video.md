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

The isolated M3 shell build and controls syntax/build checks pass. Eleven synthetic cases exercise the lifecycle-log validator, an existing-output check verifies evidence preservation, and the conflicting-opt-in invocation exits with code 2 before AppKit startup. These are nonvisual checks; the lifecycle data in those eleven cases is synthetic.

The [preserved native attempt](evidence/m3-appkit-floating-pause-control.json) passed 24 checks before its original smoke timed out waiting for zero pending frames after ordinary Pause. Its recorded pause acknowledgement and stable pending count remain failed evidence under that original criterion. Retrospective review found prior-window observations for 6 of 7 native actions; the runner failed before reaching that observer gate. The pending-count amendment and optional observation handshake above apply prospectively to a new build and capture. They do not rescore the failed run or weaken its prior-window requirement. Native acceptance remains pending.

Acceptance still requires representative HDR playback with a visible, uncovered panel; positive presentation evidence; same-frame color and subtitle comparisons; synchronization; ordinary input delivery; minimize/restore behavior; and Space/display transitions. AppKit window flags and successful compilation alone do not qualify those results. The existing ordinary-player controls regression must also pass with the opt-in absent before adoption.
