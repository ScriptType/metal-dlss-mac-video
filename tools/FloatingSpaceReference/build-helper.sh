#!/usr/bin/env bash
# Build a separate AppKit Space reference application without launching it.
set -euo pipefail
if [[ $# != 1 || "$1" != /* || -e "$1" || -L "$1" ]]; then
  printf '%s\n' 'Usage: build-helper.sh NEW_ABSOLUTE_OUTPUT.app' >&2
  exit 2
fi
space_source_dir="$(cd "$(dirname "$0")" && pwd)"
space_bundle="$1"
mkdir "$space_bundle"
mkdir "$space_bundle/Contents" "$space_bundle/Contents/MacOS"
cp "$space_source_dir/Info.plist" "$space_bundle/Contents/Info.plist"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.0 \
  "$space_source_dir/main.swift" -framework AppKit -framework CryptoKit \
  -o "$space_bundle/Contents/MacOS/FloatingSpaceReference"
printf '%s\n' "$space_bundle/Contents/MacOS/FloatingSpaceReference"
