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
