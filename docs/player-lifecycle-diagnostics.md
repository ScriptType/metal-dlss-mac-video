# Native lifecycle diagnostics

`HDRPLAYER_LIFECYCLE_LOG=/absolute/path/events.jsonl` enables a bounded diagnostic recorder in HDRPlayer. It records native property snapshots, AppKit transport hooks, real NSWorkspace notifications, and IOKit system-power callbacks. Without the variable, the recorder is absent. It never requests sleep, posts a notification, enables VoiceOver, or changes a system preference.

```sh
source scripts/env.sh
swift build --product HDRPlayer --jobs 2
HDRPLAYER_LIFECYCLE_LOG=/tmp/hdr-player-lifecycle.jsonl \
  .build/debug/HDRPlayer /absolute/path/video.mp4
```

The log includes the source path, selected video track, observed pause/playing state, pending user pause intent, approximate playback position, native rational displayed PTS, output provenance, renderer/display properties, and processing counters. `exactDisplayedPTSAvailable` is false when native output has no valid rational timebase. The recorder never converts the approximate `position` property into an exact timestamp. Original and Dolby Vision output require the adapter's rational timing property update; older adapters may omit those fields.

The writer runs on a serial background queue. Periodic snapshots are bounded to 5,000 entries, explicit events to 500; the final summary is always written. Snapshots occur roughly once per second, or at the existing native polling rate for three seconds after an event. A new invocation replaces the selected log file. Start a fresh recording for each qualification run.

`termination-requested` precedes worker shutdown. `native-worker-destroyed` is emitted after libmpv destruction returns, followed by the flushed `diagnostic-finish` summary and process exit. Native child-view counts help identify incomplete surface detachment. A recorder-only CPU check does not verify these player teardown hooks.

The existing DOM/media smoke also verifies actual teardown with the recorder enabled:

```sh
source scripts/env.sh
python3 scripts/test-player-lifecycle-playback.py
```

This command uses the native window and GPU; reserve a test window without simultaneous benchmarks or binary rebuilds. It requires the built player, patched libmpv/shared engine, model, and `player-controls.mkv` fixture used by [native player verification](native-player.md). The current M3 run passed all 22 DOM checks, captured 55 exact rational timestamp snapshots, and exited successfully after the native child-view count changed from nonzero to zero and the final log flushed. The source and paused transport state were retained in the termination snapshot. Player, libmpv, and shared-engine SHA-256 hashes were identical before and after the run. Results are written to `artifacts/player-lifecycle-playback/{report.json,dom.json,lifecycle.jsonl,player.log}`. This media-only test observed zero kernel sleep/wake cycles and provides no physical-sleep evidence.

## Sleep and wake evidence

The app records pause intent before and after its NSWorkspace sleep/wake handlers enqueue transport commands. The recorder separately observes `NSWorkspace.shared.notificationCenter` and installs an IOKit power source on the main run loop. It immediately acknowledges the power callbacks that require acknowledgement. Apple's APIs specify the [workspace sleep notification](https://developer.apple.com/documentation/AppKit/NSWorkspace/willSleepNotification) and the [IOKit acknowledgement requirement](https://developer.apple.com/documentation/iokit/1557064-ioallowpowerchange).

`physicalSleepWakeObserved` becomes true only after an IOKit `system-will-sleep` followed by `system-has-powered-on`, with no intervening `system-will-not-sleep`. Workspace notifications alone never qualify a cycle. No synthetic notification entry point exists in the recorder.

For physical qualification, wait until all builds, benchmarks, preparation jobs, and agent workloads are idle. Record a normal user-initiated macOS sleep/wake cycle while playing, then a separate cycle while paused. Inspect the actual kernel pair, unchanged source/track, valid displayed rational PTS, restored pause intent, subsequent frame progression when playing, and successful teardown. Repeat with enhancement active. This procedure has **not** been performed on the current machine; CPU checks below provide no physical-sleep evidence.

Code review found that saving only the asynchronously polled pause property could lose a just-issued Pause command before sleep and resume unexpectedly. `PlayerPauseIntent` now preserves explicit transport intent, ignores duplicate sleep notifications, and retains a pending restore until the native pause property acknowledges it. Eight CPU cases cover these transitions:

```sh
source scripts/env.sh
swiftc apps/macos/Sources/PlayerPauseIntent.swift scripts/test-player-pause-intent.swift \
  -o /tmp/player-pause-intent-check
/tmp/player-pause-intent-check

swiftc -I packages/CMpv apps/macos/Sources/PlayerLifecycleDiagnostics.swift \
  scripts/test-player-lifecycle-recorder.swift -o /tmp/player-lifecycle-recorder-check
/tmp/player-lifecycle-recorder-check /tmp/player-lifecycle-recorder-check.jsonl
```

The recorder check uses explicitly labeled test state. It validates rational-field encoding, invalid-timebase handling, excluded fields, event bounds, final flush, and actual observer registration without opening media or sending a power notification. The current M3 passed both checks; the observer registered successfully and observed zero sleep/wake cycles.

`bash scripts/test-player-lifecycle.sh` compiles and runs both CPU regressions with Swift 6, writing executables, result logs, and recorder JSONL under `artifacts/player-lifecycle-checks/`. Both `scripts/check.sh` and the GitHub Actions workflow invoke this wrapper. Observer unavailability is reported without requiring a physical power transition in CI.

## VoiceOver capability and observation

```sh
source scripts/env.sh
swift scripts/inspect-player-voiceover.swift
```

The probe reads whether VoiceOver is already enabled/running and whether Accessibility is already trusted. For a running VoiceOver process it checks existing Automation permission with `askUserIfNeeded=false`. It does not launch VoiceOver or request a new permission. Current M3 result: VoiceOver disabled/not running, Accessibility trusted, no phrase observed.

If VoiceOver and its existing scripting access are already available, a foreground player can be observed explicitly:

```sh
swift scripts/inspect-player-voiceover.swift --read-current-phrase --player-pid PLAYER_PID
```

The optional path reads the last phrase, text under the VoiceOver cursor, and caption-panel enabled state using read-only Apple events addressed to the existing process ID. Both permission checks and events prohibit consent prompts. It does not move the cursor, request an announcement, or enable the caption panel. This path remains unexecuted while VoiceOver is disabled.

The installed VoiceOver scripting dictionary exposes these read-only properties. Apple documents a separate [Allow VoiceOver to be controlled with AppleScript setting](https://support.apple.com/en-euro/guide/voiceover/cpvougen/mac) and the [caption panel's spoken-text display](https://support.apple.com/en-kw/guide/voiceover/unac078/mac). Changing either setting is outside this probe. Phrase text can establish what the screen reader reported; it does not establish audible speech quality. Sending an accessibility announcement request would not prove that VoiceOver spoke.

Existing AppKit/WebKit AX tree and real keyboard navigation checks are documented in [native player verification](native-player.md). Actual VoiceOver navigation/announcements, physical sleep/wake recovery, and moving playback between physical displays remain unverified. This machine has one built-in display.
