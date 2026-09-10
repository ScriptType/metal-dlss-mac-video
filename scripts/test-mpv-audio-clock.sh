#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"

# Exercise the production clock/drain decisions without a player or GPU build.
task_audio_clock_directory="$(mktemp -d "${TMPDIR:-/tmp}/mpv-audio-clock.XXXXXX")"
trap 'rm -rf -- "$task_audio_clock_directory"' EXIT

"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
  -I "$PROJECT_ROOT/vendor/mpv" \
  "$PROJECT_ROOT/vendor/mpv/test/hdr_audio_clock.c" \
  -o "$task_audio_clock_directory/hdr-audio-clock"
"$task_audio_clock_directory/hdr-audio-clock"
