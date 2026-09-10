# Dolby Vision paths

Dolby Vision neural enhancement is unavailable. Original frames and their metadata stay with mpv's native `gpu-next` renderer; they never enter the SDR/PQ/HLG neural importer. The application disables enhancement, quality, effect and Prepared controls for a detected Dolby Vision stream. This is a bounded original-playback path, not a generic Dolby Vision display or enhancement qualification.

| Input | Native path | Fallback and qualification |
| --- | --- | --- |
| Profile 8, compatibility ID 4 (8.4) | Parsed per-frame Dolby Vision metadata uses libplacebo reshaping | Native playback and explicit HLG-base fallback passed on the real FATE vector on M3. Base fallback requires declared compatibility and matching decoded BT.2020 YUV/HLG tags. Color accuracy remains unqualified. |
| Profile 8, compatibility ID 1 (8.1) | Parsed metadata uses libplacebo reshaping | Allow the declared HDR10 base only when decoded BT.2020 YUV and PQ tags agree. No representative local playback result yet. |
| Profile 5 | Requires parsed Dolby Vision metadata and the native reshape path | No ordinary PQ/HLG base fallback. Playback is unqualified without a representative vector. |
| Profile 7 | Native metadata path retains the enhancement layer for mpv/libplacebo pairing/composition | MEL/FEL completeness and timing remain unqualified. No automatic base-layer fallback is declared here. |
| Other Profile 8 compatibility IDs, or no container profile with parsed frame metadata | Preserve the parsed native metadata path | Unqualified. No compatible-base fallback is inferred. |
| Other declared profiles, or missing required metadata with no supported compatible base | Reject with an explicit interpretation error | Do not guess a transfer function or advertise support. |

Profile 8.1 is HDR10 compatible; Profile 8.4 is HLG compatible. These are different fallback interpretations, not interchangeable PQ inputs. [Apple HLS codec signaling](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes), [Dolby profile overview](https://ott.dolby.com/browser_test_kit/help_files/topics/r_resources.html).

## Metadata and operation order

The selected mpv stream retains the decoder configuration profile, level and base-layer compatibility ID. The filter also inspects actual decoded Dolby Vision metadata, including RPU side data, instead of relying on the container tags alone. `enhancement-state` reports `source-dolby-vision`, `native-color-path`, `enhancement-unavailable-reason` and `displayed-dolby-vision-metadata`. The latter describes the current native frame, not a pending decoded frame.

The pinned libplacebo build enables `PL_HAVE_DOVI`. FFmpeg's parsed `AVDOVIMetadata` supplies reshaping curves, nonlinear/linear matrices and available level-1 luminance metadata. The optional separate libdovi parser is disabled; its absence does not disable the FFmpeg metadata path. These are compiled capabilities, not proof of correctness for every profile.

Libplacebo normalizes the coded components, applies the per-component polynomial/MMR reshaping, composes an available FEL residual, applies the Dolby nonlinear color transform and the PQ/LMS-to-BT.2020 conversion, then performs ordinary linear-light rendering and display mapping. See [color decoding](../vendor/libplacebo/src/shaders/colorspace.c) and [FFmpeg metadata mapping](../vendor/libplacebo/src/include/libplacebo/utils/libav_internal.h). A future neural path must produce correctly reshaped linear BT.2020 nits before proxy creation and reconstruction; attaching Dolby tags to the existing generic PQ importer does not satisfy that requirement.

The passthrough preserves the complete native image, exact decoder timing, geometry, RPU/ambient metadata and any enhancement-layer references. A Dolby transition cancels admitted neural work and preparation, clears pending replacements, and disables neural clock buffering. Unsupported interpretation ends the video stream before a frame is presented through a guessed conversion. It retains an explicit error rather than asking mpv to remove the filter, because filter removal would bypass the interpretation guard. UI status distinguishes native Dolby playback from an explicitly compatible HLG/HDR10 base layer.

Profile 8.4 can include ambient-viewing metadata. Apple describes this metadata's role in adaptation; retaining it is necessary, and does not prove that a particular native renderer implements Apple's ambient strategy. [Apple TN3145](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata).

## Reproduce the bounded check

```sh
python3 scripts/fetch-dovi-fixture.py
HDRPLAYER_UI_SMOKE_KIND=dolby-vision HDRPLAYER_UI_SMOKE_REPORT=/tmp/player-dv84.json \
  .build/debug/HDRPlayer assets/test-clips/dolbyvision/dv84.mov
python3 scripts/test-dovi-passthrough.py
```

The 3,621,742-byte sample is FFmpeg's public `hevc-dv-rpu` regression vector. Its SHA-256 is `aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721`. The fetch script verifies that hash and leaves the binary untracked for local testing. It is a 1920×1080, rotated, approximately 3.33-second Profile 8.4 MOV with parsed frame RPU and ambient metadata. [FFmpeg FATE test](https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html), [public sample index](https://fate-suite.ffmpeg.org/hevc/).

The DOM check passed seven assertions on M3: actual native-frame metadata, stream profile/compatibility, disabled enhancement controls, rejection of a direct enhancement command, pause, exact seek and no playback error. The selected native surface was PQ EDR (Metal format 94), and neural submissions remained zero. The separate CLI check passed native playback with enhancement requested, explicit HLG-base playback, and deliberately inconsistent signaling with disabled metadata mapping. That last case is a synthetic negative guard test, not Profile 5 playback coverage: it requires no filter auto-removal and no video output. Its report and logs are written to `artifacts/dovi-passthrough/`.

These checks do not establish calibrated color accuracy, Dolby certification, display metadata passthrough or Profile 5/7/8.1 support. Those claims require separate representative assets and output comparisons; roadmap #18 remains open.
