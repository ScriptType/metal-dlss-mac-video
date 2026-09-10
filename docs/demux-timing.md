# Demux origin and end range

The native demuxer now recovers a missing playback origin from known audio/video stream headers and extends the duration when a later stream endpoint proves that the existing estimate is too short. The fix is published in mpv `a9466025dcf459f82f591f42dc12a517a50e7efa`. It leaves original source packet timestamps and media payloads intact; existing player rebasing now uses the recovered origin. It does not enable additional stream probing.

The defect appeared in the pinned Apple Dolby Vision Profile 5 MP4: the player began at 10 seconds while its slider ended at 98.475667 seconds, excluding valid near-end frames around 108 seconds in the original file timeline. The AAC track starts at 9.956 seconds, before the video's 10-second start. The Apple HDR10+ MP4 additionally has a later video endpoint, making the former duration estimate one video frame too short.

| Source | Earliest audio/video start | First video PTS in file | Last video PTS in file | Correct player duration |
| --- | --- | --- | --- | --- |
| Apple Profile 5 | 9.956 s | 240000/24000 = 10 s | 2601359/24000 | 98.475666667 s |
| Apple HDR10+ | 9.956 s | 241001/24000 | 2602360/24000 | 98.517375 s |

The [timing evidence](evidence/m3-demux-header-timing.json) pins the input, source, library, binary and report hashes. The original failing near-end report and the successful `probe-info=yes` control remain separate from the final default-options checks.

## Cause and scope

The linked FFmpeg 9.0.1 library leaves `AVFormatContext.start_time` and `duration` unknown immediately after `avformat_open_input()` on these MP4s. Their stream headers already contain valid starts, durations and edit-list timing. Reading every packet without `avformat_find_stream_info()` still leaves the aggregate fields unknown. Enabling that function fills the aggregate origin without changing packet order, timestamps or payloads in the seven measured inputs.

mpv deliberately skips full stream probing for selected formats, including MP4. Its former initialization used the unknown aggregate start while choosing a known duration from the individual tracks. This combined different origins. The fallback uses only known, nonattached audio/video stream starts when the aggregate start is absent. It preserves a supplied aggregate origin and the existing longer duration estimate. It ignores subtitle/data tracks and cover images; this is a deliberately narrower policy than FFmpeg's complete aggregate inference. See the upstream [FFmpeg timing implementation](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavformat/demux.c).

The helper adds start and duration in each stream's original integer tick domain, checks arithmetic and rescale overflow, then converts each endpoint once to `AV_TIME_BASE`. A known span extends the existing duration only when it exceeds the existing duration's enclosing microsecond. Thus a rounded endpoint cannot add a spurious sub-microsecond tail to a more precise track duration. Profile 5 and the fractional zero-start controls retain their original `double` values; HDR10+'s proven 41.708333 ms extension remains. Unknown timing or invalid time bases do not invent a range. The fix does not scan packets, change the rebase option, or alter decoded color handling.

## File, decoder and player coordinates

With the default rebase option enabled, the existing player applies a timestamp offset of `−9.956` seconds to these sources before decoding. The first Profile 5 video frame therefore has three related identities:

| Coordinate | Exact video timestamp |
| --- | --- |
| Original file | 240000/24000 |
| Decoder after demux offset | 1056/24000 |
| Player | 0.044 s |

The player value in the table describes the settled mapping. The `enhancement-state.displayed-source-pts` property and native exporter report the decoder timestamp after the offset. Recover the original file timestamp by subtracting the applied offset. A nominal source timestamp must not be compared directly with the rebased player slider. The validation harnesses retain all three coordinates and verify the offset in exact video ticks (`−238944/24000` here).

Prepared decoding opens an independent demuxer, applies the active player's offset once and preserves the same decoder PTS/duration policy. Its provider identity includes the mpv revision and offset, so a cache prepared with the former zero offset cannot be treated as the same timing interpretation. Final Prepared validation uses the binary built after the published fix commit.

## Verification

The focused `lavf-timing` test passes 18 checks: the Apple audio lead and differing video endpoint, supplied origins, longer estimates, excluded tracks, zero and negative starts, exact fractional-duration preservation, a span beyond the enclosing microsecond, missing/invalid timing and arithmetic/rescale overflow. Seven CPU controls cover Apple Profile 5, Apple HDR10+, FATE Profile 5 and 8.4, PQ, SDR and HLG MP4s. All inferred origins match the fully probed aggregate origins for these inputs. Every off/on probing pair has identical ordered packet-timing and packet-payload digests; the five zero-origin fixtures remain at zero.

The final clean core binary passes default `probe-info=auto` native first- and last-frame selection for both Apple sources. The first observation proves file↔decoder identity only: the initial `time-pos` property is still zero, so it does not establish a settled first-frame player mapping. The last-frame observation verifies file, decoder and player coordinates. Both processes exit successfully, with unchanged binaries and zero neural submissions. Profile 5 reports 98.475667 seconds through mpv's property serialization; HDR10+ reports 98.517375 seconds. Both last-frame targets lie inside their player range. Earlier native/app checks used the preceding timing candidate; their exact build hashes remain recorded separately.

The final Profile 5 app repeat passes 22 checks on the published core: a held source/player mapping, three exact representative selections and interpreted screenshots, progression, the actual DOM near-end seek and slider range, metadata-loss rejection and clean teardown. Its three observation windows contain 10, 9 and 10 distinct original PTS over 1.263, 1.249 and 1.260 seconds, with active, unoccluded windows and no sampled pause/buffer state. The preceding run failed the short app progression check; its native selections and near-end check passed, and the cause of the sampled stall remains unresolved. That failure is retained. The repeat adds app-only sample diagnostics and keeps the same threshold; the core/shared binaries are unchanged.

The [final nonzero-origin Prepared regression](evidence/m3-apple-prepared-nonzero-start.json) passes on the published core. Three held observations after restart completion verify decoder PTS 2057/24000 against player 0.085708 seconds, within 1 µs, resolving the initial unsettled-property limitation for this HDR10+ source. Six real-NR frames at processing size 32×24 retain full 1920×1080 cache geometry. Exact decoder PTS 5060/24000 hits `prepared-enhanced`; 13068/24000 outside coverage displays `original`. Reopening reuses both segments with zero processing and identical manifest/payload hashes. The two segments use 199,070,297 logical bytes within a 256 MiB cache, and all playback/guard processes exit.

Independent CPU review reproduced all four archived manifests' full identity keys and exact PTS/duration digests, their file-to-decoder offsets, and the recorded source/provider/settings identities. Cache pixels were verified during both live phases before temporary storage was removed; this later review cannot reread those removed payloads. All six opening source frames are black, and their recorded payload hashes match independently computed Float32 RGBA `(0,0,0,1)`. This result establishes timing/cache integration with the neural configuration, without adding varied-scene reconstruction-quality evidence. The separate [natural HDR10+ held-frame check](apple-hdr-playback.md#recorded-m3-result) records its own earlier timing candidate and display limits.

These checks establish timing, seekability and cache identity for the measured files. They do not qualify physical display color, compositor brightness or scanout timing.

## Reproduction

Build the core normally, then run the focused CPU test:

```sh
source scripts/env.sh
meson compile -C artifacts/mpv-build lavf-timing -j2
meson test -C artifacts/mpv-build --no-rebuild lavf-timing --print-errorlogs
```

`scripts/test-cores.sh` includes this test in its complete mpv Meson suite. The app/source harnesses accept fresh output paths and preserve the original-file/decoder/player mapping. Use the pinned Apple source path explicitly when its corpus download lives under `artifacts/public-hdr-source-audit/`; the evidence records the exact commands and hashes. The historical `--demuxer-lavf-probe-info=yes` setting is an isolation control, not a required user setting.
