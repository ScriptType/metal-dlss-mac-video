# HDR compositor capture

The public ScreenCaptureKit helper captures one explicitly identified HDR Player,
workspace player or `com.apple.PIPAgent` window. It supports relative compositor
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
request. Unbundled workspace executables require `--owner-bundle unbundled`;
PIPAgent requires its actual PID and `com.apple.PIPAgent`.

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

The existing system-PiP inspection launcher supplied the paused PQ fixture at
exact source PTS `20000000/1000000`, generation 3, revision 14, enhanced content
kind 2 and clock rate 0. These identities remained equal before and after every
capture. The launcher uses real NR at 32×24 for instrumentation; this is not an
intended-quality workload. Reproduce setup with
`python3 scripts/start-system-pip-check.py --output artifacts/new-session`, then
use its `live.json` and title-free owner discovery to select the explicit window
IDs. Creating `artifacts/new-session/finish` requests orderly teardown.

All HDR buffers carried the same actual Display P3 ICC profile
(`0ff6958f98684c61f6bbdce1368ddeaf3873baf84545baba482e920d92a914c0`),
IOSurface headroom 1, and no RGB components above 1. The screen reported current
and potential EDR 16. Alpha mode, reference-white nits and per-sample attachments
were absent. Local and canonical PiP captures were byte-identical. These facts
do not establish that the capture retained the original HDR brightness domain.

The native window captured the full fixture with dark encoded video values.
PiP captured a bright, enlarged red/green subregion. Both SDR and HDR captures,
with scaling enabled and disabled, reproduced the geometry discrepancy. The
PIPAgent AX bounds and SCK frame matched at 444×245 points; its rightmost four
points were outside the 1800-point display. A target-only display capture of the
visible 440×245-point intersection matched the desktop-independent capture
exactly across all 372,624 paired opaque pixels in the shared 880×490-pixel ROI;
58,576 nonopaque pixels were excluded. This rules out row-stride handling,
`scalesToFit` and the independent-window filter as sole explanations. It does
not yet locate the discrepancy among producer, AVSampleBufferDisplayLayer and
system PiP.

The first wrong-bundle enumeration and two stricter whole-display requests were
rejected before pixel capture and remain in the evidence. All raw captures,
metadata and clipped review previews are retained under
`artifacts/sck-hdr-compositor-*`. Preview PNGs are convenience views of encoded
values; they are not HDR reference images. Native/PiP geometry and color
equivalence remain unqualified pending pre-compositor buffer isolation and
matched content/geometry tests.
