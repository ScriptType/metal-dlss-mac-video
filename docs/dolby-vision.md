# Dolby Vision paths

Dolby Vision neural enhancement is unavailable. Original frames and their metadata stay with mpv's native `gpu-next` renderer; they never enter the SDR/PQ/HLG neural importer. The application disables enhancement, quality, effect and Prepared controls for a detected Dolby Vision stream. This is a bounded original-playback path, not a generic Dolby Vision display or enhancement qualification.

| Input | Native path | Fallback and qualification |
| --- | --- | --- |
| Profile 8, compatibility ID 4 (8.4) | Parsed per-frame Dolby Vision metadata uses libplacebo reshaping | Native playback and explicit HLG-base fallback passed on the real FATE vector on M3. Base fallback requires declared compatibility and matching decoded BT.2020 YUV/HLG tags. Color accuracy remains unqualified. |
| Profile 8, compatibility ID 1 (8.1) | Parsed metadata uses libplacebo reshaping | Allow the declared HDR10 base only when decoded BT.2020 YUV and PQ tags agree. No representative local playback result yet. |
| Profile 5 | Requires parsed Dolby Vision metadata and the native reshape path | Native routing, exact short seek and missing-metadata rejection passed on the constant FATE vector on M3. No ordinary PQ/HLG base fallback; representative content and color accuracy remain unqualified. |
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

## Reproduce the bounded checks

```sh
source scripts/env.sh
swift build --product HDRPlayer --jobs 2
python3 scripts/fetch-dovi-fixture.py
python3 scripts/test-dovi-passthrough.py --app --report artifacts/dovi-profile84/report.json
python3 scripts/fetch-dovi-fixture.py --profile 5
python3 scripts/test-dovi-passthrough.py --profile 5 --app --report artifacts/dovi-profile5/report.json
```

Profile 8.4 remains the default. `--source` accepts another local path only when its size and SHA-256 match the selected pinned fixture. The CLI checks decoded RPU metadata, selected stream profile/compatibility, zero neural work, native seek and profile-specific fallback behavior. `--app` adds the shipped DOM controls and orderly native teardown checks. Direct app diagnostics use `HDRPLAYER_UI_SMOKE_KIND=dolby-vision`, `HDRPLAYER_UI_SMOKE_REPORT=/absolute/report.json` and optional `HDRPLAYER_DV_PROFILE=5` (default `8.4`). Reports retain decoded metadata, native logs, before/after binary hashes and failures.

The Profile 8.4 sample is FFmpeg's public `hevc-dv-rpu` regression vector: 3,621,742 bytes, SHA-256 `aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721`. It is a rotated 1920×1080 MOV lasting approximately 3.33 seconds, with parsed frame RPU and ambient metadata. [FFmpeg FATE test](https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html), [public sample index](https://fate-suite.ffmpeg.org/hevc/).

The Profile 5 sample is FFmpeg FATE's `mov/dovi-p5.mp4`: 4,182 bytes, SHA-256 `11fe599fd77e31e26fbf855bae1cd9931df9f261a0a7b1dce9fad9b236677c4b`. It has ten constant 1920×1080 full-range frames at 24 fps, no audio, Profile 5/level 4, compatibility ID 0, a base layer and RPU but no enhancement layer. Its contributor identifies it as blank x265 video with Dolby configuration added before remuxing. It exercises metadata interpretation and rejection, not varied-color or motion rendering. The approximately 0.417-second duration requires the in-range 0.125-second seek rather than the Profile 8.4 target of 0.7 seconds. [Contributor provenance](https://ffmpeg.org/pipermail/ffmpeg-devel/2021-December/289651.html), [public sample index](https://fate-suite.ffmpeg.org/mov/).

Both downloads remain untracked. The fetcher verifies size and hash before installing each fixture and writes a source manifest. No explicit per-file redistribution license was found in the inspected FATE index or contribution; FFmpeg's source-code licenses are not treated as media licenses.

On M3, both profiles passed seven app assertions: actual native-frame metadata, pinned profile/compatibility, disabled enhancement controls, rejection of a direct enhancement command, pause, displayed-frame seek and no playback error. Native submissions remained zero and the native core was destroyed before process exit. Profile 5 selected source PTS `1536/12288 = 0.125` seconds. Profile 8.4 native and explicit HLG-base cases both selected `840/1200 = 0.7` seconds. [Profile 5 and default-regression evidence](evidence/m3-dovi-profile5.json).

Disabling metadata mapping on the actual Profile 5 input rejected video with no neural submission, video output or filter auto-removal; the video-only process exited with input-error status 2. The Profile 8.4 negative test deliberately changes only container signaling to declare no compatible base while retaining its HLG/RPU payload, then disables metadata mapping. This is a synthetic rejection check, separate from actual Profile 5 playback. Its video is rejected, while its retained audio can finish with process status 0.

These checks do not establish calibrated color accuracy, Dolby certification, display metadata passthrough, representative Profile 5 playback, or Profile 7/8.1 qualification. Those claims require separate assets and output comparisons; roadmap #18 remains open.
