# Dolby Vision paths

Native original playback is demonstrated for Profile 5 and Profile 8.4 on the pinned M3 build, within the fixture and interpreted-output checks below. Dolby Vision neural enhancement is unavailable. Original frames and their metadata stay with mpv's native `gpu-next` renderer; they never enter the SDR/PQ/HLG neural importer. The application disables enhancement, quality, effect and Prepared controls for a detected Dolby Vision stream. Physical display accuracy and other profiles are outside this claim.

| Input | Native path | Fallback and qualification |
| --- | --- | --- |
| Profile 8, compatibility ID 4 (8.4) | Parsed per-frame Dolby Vision metadata uses libplacebo reshaping | Native playback, exact seek, interpreted output and explicit HLG-base fallback passed on the real FATE vector on M3. Base fallback requires declared compatibility and matching decoded BT.2020 YUV/HLG tags. |
| Profile 8, compatibility ID 1 (8.1) | Parsed metadata uses libplacebo reshaping | Allow the declared HDR10 base only when decoded BT.2020 YUV and PQ tags agree. No representative local playback result yet. |
| Profile 5 | Requires parsed Dolby Vision metadata and the native reshape path | Representative Apple footage passed native playback, exact source/player seeks, interpreted-output inspection and app controls. The constant FATE vector retains its short-seek regression. Missing metadata rejects video; no ordinary PQ/HLG base fallback. |
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

Profile 8.4 remains the default. `--source` accepts another local path only when its size and SHA-256 match the selected pinned fixture. The CLI checks decoded RPU metadata, selected stream profile/compatibility, zero neural work, native seek and profile-specific fallback behavior. `--app` adds the shipped DOM controls and orderly native teardown checks. Direct app diagnostics use `HDRPLAYER_UI_SMOKE_KIND=dolby-vision`, `HDRPLAYER_UI_SMOKE_REPORT=/absolute/report.json` and optional `HDRPLAYER_DV_PROFILE=5` (default `8.4`). Each CLI run requires a new report directory and refuses existing native/app logs or screenshots. Reports retain decoded metadata, exact timing, before/after binary and selected-source hashes, and failures.

The Profile 8.4 sample is FFmpeg's public `hevc-dv-rpu` regression vector: 3,621,742 bytes, SHA-256 `aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721`. It is a rotated 1920×1080 MOV lasting approximately 3.33 seconds, with parsed frame RPU and ambient metadata. [FFmpeg FATE test](https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html), [public sample index](https://fate-suite.ffmpeg.org/hevc/).

The Profile 5 sample is FFmpeg FATE's `mov/dovi-p5.mp4`: 4,182 bytes, SHA-256 `11fe599fd77e31e26fbf855bae1cd9931df9f261a0a7b1dce9fad9b236677c4b`. It has ten constant 1920×1080 full-range frames at 24 fps, no audio, Profile 5/level 4, compatibility ID 0, a base layer and RPU but no enhancement layer. Its contributor identifies it as blank x265 video with Dolby configuration added before remuxing. It exercises metadata interpretation and rejection, not varied-color or motion rendering. The approximately 0.417-second duration requires the in-range 0.125-second seek rather than the Profile 8.4 target of 0.7 seconds. [Contributor provenance](https://ffmpeg.org/pipermail/ffmpeg-devel/2021-December/289651.html), [public sample index](https://fate-suite.ffmpeg.org/mov/).

Both downloads remain untracked. The fetcher verifies size and hash before installing each fixture and writes a source manifest. No explicit per-file redistribution license was found in the inspected FATE index or contribution; FFmpeg's source-code licenses are not treated as media licenses.

On M3, both profiles passed seven app assertions: actual native-frame metadata, pinned profile/compatibility, disabled enhancement controls, rejection of a direct enhancement command, pause, displayed-frame seek and no playback error. Native submissions remained zero and the native core was destroyed before process exit. Profile 5 selected source PTS `1536/12288 = 0.125` seconds. Profile 8.4 native and explicit HLG-base cases both selected `840/1200 = 0.7` seconds. [Profile 5 and default-regression evidence](evidence/m3-dovi-profile5.json).

Disabling metadata mapping on the actual Profile 5 input rejected video with no neural submission, video output or filter auto-removal; the video-only process exited with input-error status 2. The Profile 8.4 negative test deliberately changes only container signaling to declare no compatible base while retaining its HLG/RPU payload, then disables metadata mapping. This is a synthetic rejection check, separate from actual Profile 5 playback. Its video is rejected, while its retained audio can finish with process status 0.

## Representative Apple Profile 5 fixture

The separate `apple-profile5` fixture selects Apple's clear developer-streaming example, remuxed with its original stereo AAC packets. It has Profile 5/level 3 with compatibility ID 0. The local MP4 pin is 42,855,591 bytes, SHA-256 `69bbb93355cb91d69eefe7f24f6525e61670aa3ae25bbfb4a546a19a0358e110`. Original fragment URLs, hashes and usage scope are in [the Apple source catalog](../config/apple-hdr-samples.json). Its acquisition and packet-preservation checks are separate from playback qualification. The media remains untracked. [Apple publisher page](https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html).

```sh
python3 scripts/fetch-apple-hdr-samples.py dolby-profile5
python3 scripts/test-dovi-passthrough.py --fixture apple-profile5 --app \
  --report artifacts/dovi-apple-profile5/report.json
```

`--profile 5` continues to select the small FATE fixture; profile numbers are not fixture identifiers. The Apple check inventories all 2,360 actual video presentation timestamps and chooses three frames across the clip. Its video begins at original file PTS `240000/24000 = 10` seconds; AAC begins at `477888/48000 = 9.956` seconds. The harness observes the active native `demuxer-start-time` and `options/rebase-start-time`, rather than assuming the standalone ffprobe format summary describes the player. mpv rebases packets before decoding: the native exact `displayed-source-pts` is a decoder timestamp. The harness subtracts the observed demux offset to recover original file PTS and checks exact inventory membership. Nonintegral offsets in the pinned timebase are rejected rather than rounded silently.

With ordinary defaults, native start is `9.956` seconds and the file-to-decoder offset is `−238944/24000`; first video appears at player time `0.044`. Exact original targets `528288/24000`, `1248007/24000` and `1968727/24000` pass native and DOM seeks, followed by progressing playback with parsed Dolby metadata and zero neural submissions. The app's millisecond slider request is recorded before dispatch, and the selected original PTS must still match exactly. The near-end source frame `2589347/24000` maps to player `97.933458…`, within duration `98.475667`; both the actual slider and the direct native bridge reach it. The app receives the source-bound inventory through `HDRPLAYER_DV_INVENTORY`; direct diagnostics select `HDRPLAYER_DV_FIXTURE=apple-profile5`.

The prior default mp4 path skipped aggregate stream probing and reported origin zero with a shorter duration, clipping the slider despite direct native seeks reaching later frames. The retained baseline documents that failure. An explicit `--probe-info-control` demonstrated the corrected origin. The final native fix derives missing timing from known primary audio/video stream headers and preserves supplied aggregate timing; ordinary app options now pass without that diagnostic override. See [the timing helper](../vendor/mpv/demux/lavf_timing.h) and the evidence below.

The final Apple run passes 22 app checks. The missing-metadata negative check explicitly disables audio and Dolby metadata mapping, then requires video rejection, zero neural work and input-error exit status 2. It never substitutes an ordinary PQ/HLG interpretation of Profile 5. The final FATE Profile 5 and default Profile 8.4 regressions each pass seven app checks, including native teardown. Eleven CPU checks cover fixture identity, metadata guards, exact timing and refusal to overwrite evidence.

One retained app follow-up failed the short progression threshold while its native checks passed; the cause of its reported PTS stall remains unresolved. A bounded repeat kept the same threshold and recorded 10, 9 and 10 distinct original frame timestamps in three approximately 1.25-second observation windows, with the app active, window visible on the active Space, and no pause or buffering. This establishes progressing representative playback, not continuous presentation cadence.

Three same-target Apple screenshots show full 1920×1080 natural scenes: a dark interior, a daylight family scene and a backlit adult with a child. Profile 8.4 native and HLG-base screenshots at exact source `0.7` seconds show the full upright 1080×1920 coastal scene. Both independent reviewers found nonblank, coherent geometry and colors without an obvious global channel tint or crop. These are libplacebo's separate screenshot-render outputs, not raw swapchain, SCK/compositor or physical-display captures. [Final native Profile 5/8.4 evidence](evidence/m3-dovi-apple-profile5.json).

The demonstrated scope is native Profile 5 and Profile 8.4 interpretation, representative playback, app gating and declared fallback/rejection. Profile 7 and 8.1 remain unqualified and unadvertised. These checks do not establish calibrated HDR luminance, Dolby certification, ambient adaptation, display metadata passthrough or neural Dolby enhancement; physical display calibration remains part of roadmap #3.
