# Contributing

Read `mac-hdr-player-plan.md`, `docs/setup.md`, and `docs/implementation-handoff.md` before changing the pipeline. Keep source, proxy, and HDR reconstruction domains explicit. Do not describe SDR export or an 8-bit screenshot as HDR validation.

Keep changes small and follow the existing Swift/AppKit, Python, and shell structure. Pin source revisions and package changes deliberately. Never commit model files, recordings, local traces, credentials, or generated build outputs.

Run `bash scripts/check.sh` for local changes. Run the relevant upstream suite when changing a submodule. Record exact inputs, resolutions and completed GPU work for performance claims; the M5 profile has no established performance target yet.
