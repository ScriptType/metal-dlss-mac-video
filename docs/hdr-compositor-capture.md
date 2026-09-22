# HDR compositor capture

The public ScreenCaptureKit helper captures one explicitly identified HDR Player
or workspace player window. It supports relative compositor
diagnostics. It does not measure panel luminance, physical scanout or acoustic
synchronization, and successful capture does not qualify HDR playback.

## Capture contract

Build with `bash scripts/build-hdr-capture-probe.sh`. The helper links only system
frameworks and does not rebuild mpv or FrameEngineShared. macOS 15 or newer on
Apple Silicon is required for the HDR presets. The installed SDK used for this
probe was macOS 26.5. Apple documents the HDR presets and their local versus
canonical display intent in [Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/).

```sh
probe=artifacts/hdr-capture-probe/hdr-capture-probe
"$probe" --preflight
"$probe" --owner-pid "$target_pid" --owner-bundle "$target_bundle" --list-windows
"$probe" --owner-pid "$target_pid" --owner-bundle "$target_bundle" \
  --window-id "$target_window" --output artifacts/my-new-capture \
  --frame-reference artifacts/paused-frame-identity.json
```

`--preflight` calls only `CGPreflightScreenCaptureAccess`. Denied access fails
without requesting permission or changing privacy settings. Listing returns
metadata for the specified owner and omits window titles. Capture revalidates the
PID, bundle, executable allowlist and window ownership before and after the
request. Unbundled workspace executables require `--owner-bundle unbundled`.

The default is the public local-display HDR screenshot preset, a desktop-independent
single-window filter, native backing dimensions, no cursor, child windows or
shadows, and no audio. `--canonical` selects the canonical HDR intent. Each
operation has a 20-second deadline, an 8-megapixel/96-MiB pixel bound, and requires
a new output directory.

The report preserves requested configuration and actual pixel metadata: ICC data
and hashes, CGColorSpace when supplied, both CVBuffer attachment modes, both
CMSampleBuffer attachment modes, sample attachments, IOSurface headroom, row
stride, alpha information, sample timing and exact mach ticks/timebase. Raw RGhA
half-float pixels are copied without transfer conversion, clipping or alpha
unpremultiplication. Non-pixel row padding is zeroed while its stride is retained.
Missing metadata remains unavailable. Half-float does not imply linear light,
and headroom is a ratio rather than an absolute luminance value. The optional
frame-reference JSON is explicitly labeled caller-supplied; screenshot PTS does
not identify the source video frame.

Three controls isolate capture behavior:

- `--scale-to-fit` changes only the public scaling flag. The default prevents
  capture upscaling; width and height still use the native backing scale.
- `--sdr-control` requests BGRA8/sRGB/SDR and writes `pixels.bgra8`, with actual
  metadata. It is a geometry control, not an HDR reference.
- `--display-bound` includes only the target window on the one intersecting
  display and sets an explicit source rectangle to its visible intersection.
  Desktop, dock, menu and every other window are excluded. It currently requires
  the display at logical origin and records any display-edge crop.

## Offline analysis

```sh
.venv/bin/python scripts/analyze-hdr-capture.py artifacts/my-new-capture
.venv/bin/python scripts/analyze-hdr-capture.py artifacts/first \
  --compare artifacts/second --roi-first 0,0,880,490 --roi-second 0,0,880,490
.venv/bin/python scripts/test_hdr_capture.py
```

The analyzer verifies payload lengths and hashes, honors row padding, and reports
negative, above-one, nonfinite and nonopaque values. Optional comparisons require
explicit equally sized ROIs, matching actual ICC data and capture intent. There
is no inferred registration or resampling. The supported color conversion is
limited to the observed RGB matrix/parametric-type-3 ICC profile, opaque finite
encoded components in `[0,1]`, and relative XYZ D50. It reads the actual profile
parameters, does not apply chromatic adaptation twice, and excludes unsupported
extended or alpha values with counts. The curve is defined by the
[ICC profile specification](https://www.color.org/ICC1-V41.pdf). Arbitrary ICC
profiles, HDR extrapolation and absolute nits are unsupported. Seven CPU tests
cover the transfer, payload, stride, ICC, alpha, finite-value and comparison guards.

## M3 capture evidence

[The compact report](evidence/m3-hdr-compositor-capture.json) references three
sessions containing 15 successful pixel captures. All player sessions exited
cleanly and their player, mpv and shared-engine binaries stayed unchanged. The
helper was an uncommitted development build; every capture records its executable
hash. Geometry controls evolved between sessions. The final source additionally
checks the optional reference-file size before reading it; that bounded CPU-only
change was compiled after the captures.

All HDR buffers carried the same Display P3 ICC profile
(`0ff6958f98684c61f6bbdce1368ddeaf3873baf84545baba482e920d92a914c0`),
IOSurface headroom 1, and no RGB components above 1, while the screen reported
current and potential EDR 16. Alpha mode, reference-white nits and per-sample
attachments were absent. These captures therefore do not establish that the
capture retained the original HDR brightness domain.

These sessions also compared the native window with the system picture-in-picture
window. That route was dropped; [picture-in-picture](picture-in-picture.md)
records why.
