#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"

# CPU-only: no player/window, decoder, GPU job, physical power transition,
# synthetic notification, VoiceOver activation, or OS preference write.
mkdir -p artifacts/player-lifecycle-checks
swiftc -swift-version 6 apps/macos/Sources/PlayerPauseIntent.swift scripts/test-player-pause-intent.swift \
  -o artifacts/player-lifecycle-checks/pause-intent
artifacts/player-lifecycle-checks/pause-intent | tee artifacts/player-lifecycle-checks/pause-intent.log
swiftc -swift-version 6 -I packages/CMpv apps/macos/Sources/PlayerLifecycleDiagnostics.swift \
  scripts/test-player-lifecycle-recorder.swift -o artifacts/player-lifecycle-checks/recorder
artifacts/player-lifecycle-checks/recorder artifacts/player-lifecycle-checks/recorder.jsonl \
  | tee artifacts/player-lifecycle-checks/recorder.log
swiftc -swift-version 6 -I packages/CMpv apps/macos/Sources/MPVFrameExport.swift \
  apps/macos/Sources/PiPCoreClock.swift scripts/test-player-pip-clock.swift \
  -o artifacts/player-lifecycle-checks/pip-clock
artifacts/player-lifecycle-checks/pip-clock | tee artifacts/player-lifecycle-checks/pip-clock.log
swiftc -swift-version 6 apps/macos/Sources/PiPRequestState.swift scripts/test-player-pip-requests.swift \
  -o artifacts/player-lifecycle-checks/pip-requests
artifacts/player-lifecycle-checks/pip-requests | tee artifacts/player-lifecycle-checks/pip-requests.log
