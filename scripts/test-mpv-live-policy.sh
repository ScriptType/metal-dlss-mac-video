#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"

# Compile the production policy test directly; no player or GPU runtime build.
task_live_policy_directory="$(mktemp -d "${TMPDIR:-/tmp}/mpv-live-policy.XXXXXX")"
trap 'rm -rf -- "$task_live_policy_directory"' EXIT

"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
  -I "$PROJECT_ROOT/vendor/mpv" \
  "$PROJECT_ROOT/vendor/mpv/test/metal_hdr_live_policy.c" \
  -lm -o "$task_live_policy_directory/metal-hdr-live-policy"
"$task_live_policy_directory/metal-hdr-live-policy"
