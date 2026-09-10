#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
mkdir -p artifacts/pip-accessibility
# Standalone CPU build; does not build or link the app, libmpv or shared engine.
swiftc -swift-version 6 -parse-as-library scripts/system-pip-accessibility.swift \
  -o artifacts/pip-accessibility/SystemPiPAccessibility
