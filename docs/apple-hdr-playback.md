# Apple HDR playback diagnostics

The pinned [Apple developer streaming sample](https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html) provides a real-scene HDR10+ PQ rendition and shared AAC audio. Original playlists, segment hashes, packet-preserving remux verification and separate Dolby Vision provenance are recorded in [the source catalog](../config/apple-hdr-samples.json) and [source audit](open-content-reference.md). HDR10+ dynamic metadata remains part of the original source description.

## Native HDR10+ transition check

Build the separate diagnostic host, then use a new output directory:

```sh
bash scripts/build-hdr-source-transition-probe.sh
python3 scripts/test-apple-hdr-playback.py \
  --metadata-only --output artifacts/apple-hdr10plus-native-metadata
```

The wrapper verifies the pinned remux and all 2,360 decoded frame timestamps, durations and PQ/HDR10+ tags before opening the native host. `--prepare-only` stops after that software preflight. The default run without `--metadata-only` also requests one native ScreenCaptureKit capture and requires actual window visibility and unchanged geometry. It never requests capture permission or changes display settings.

The host uses the existing libmpv `gpu-next/macvk` path and one actual neural result at processing size 160×96, with a full 1920×1080 output. It observes original PQ, enhanced RGB, retained original and retained enhanced at the same file frame, then checks the final source frame through original passthrough. It does not change target peak, layer metadata, colour settings or the reconstruction algorithm.

Timing has three coordinates. The original file inventory is unchanged. mpv's demux packet offset can change timestamps before decoding; the exporter's `source_pts` therefore identifies the native decoder frame. Its `source_to_player_seconds` describes the separate decoder-to-player mapping. The harness validates both transformations and rejects an offset that is not representable in the pinned file timebase.

## Recorded M3 result

[The evidence record](evidence/m3-apple-hdr10plus-playback.json) pins source, binary, script and timing-code hashes. The native host exited successfully with 13 checks. Its wrapper initially rejected valid CV attachments because the validator expected short key aliases. A regression using the actual `CVImageBufferColorPrimaries` and `CVImageBufferTransferFunction` dictionary shape fixed the validator; separate CPU revalidation passed against the unchanged saved session and pixels. The original failed wrapper remains preserved.

The selected face frame has original file PTS 1742501/24000. With the observed packet offset −238944/24000, native decoder PTS is 1503557/24000 and the decoder-to-player offset is zero. Native original and retained original expose the same HDR10+ scene values: R 541.700012, G 472.899994, B 522.5 and average 52 nits. These source scene fields are absent from reconstructed linear BT.2020 RGB.

Retained comparison advanced selected revisions 15 → 17 → 19 within generation 4. Submitted and completed counts stayed at one. Both 16,588,800-byte normalized RGBA16F copies have SHA-256 `caf14f806accaa97affd81cc5cae8846ff2f9f5cbb5856cec835a40a827c9e35`. Two consumer leases were observed at most, followed by an actual zero-leases snapshot before exporter close and successful core destruction.

Source and native target both report `max-luma` 342.446075 nits. The actual layer is RGBA16Float, extended-linear BT.2020 with EDR enabled and output-mapping metadata present. The configured optical scale of 203 nits per float unit is established by the reviewed source assignment; the metadata description does not expose a public optical-scale getter. Readback has no nonfinite components. Its largest RGB component, 407.189453125 nits, is distinct from the luminance metadata maximum.

The original-only end check selected file PTS 2602360/24000, decoder PTS 2363416/24000, and duration 1001/24000. Its frame end and the declared native playback end both equal 98.517375 seconds. This check admitted no additional neural work.

This capture used metadata-only mode. The source window later moved off the active Space, so the evidence makes no compositor acceptance claim. One held frame does not qualify sustained natural playback, HDR10+ dynamic display mapping, calibrated colour or physical A/V synchronization. A later precision-only duration refinement has separate native end-range controls; the captured candidate's timing sources and hashes remain archived.

## Prepared nonzero-start regression

The bounded Prepared smoke first opens and cleanly closes an original bypass process to observe native timing. It maps the first six exact file frames into the active decoder/cache coordinates, then opens two Prepared processes using that mapping:

```sh
python3 scripts/test-mpv-prepared.py \
  --source artifacts/public-hdr-source-audit/apple-advanced-hdr10plus-aac.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --report artifacts/apple-hdr10plus-prepared.json
```

Neural processing is 32×24; cache output retains the full 1920×1080 geometry. Six RGBA Float32 frames require 199,065,600 payload bytes, so the harness selects a bounded 256 MiB cache. It verifies source/model identity, the provider's actual native version and numeric packet offset, exact timing digests, payload hashes, cache hits, an original miss and zero-work reuse after reopening. Raw manifests are retained beside the report before temporary payload storage is removed. This invocation is an integration regression, with no Live or throughput acceptance claim.

The [M3 nonzero-start evidence](evidence/m3-apple-prepared-nonzero-start.json) passed against mpv commit `a9466025d` with unchanged binaries. The origin probe waits for restart completion, then checks three held paused decoder/`time-pos` pairs over at least 100 ms. The adapter's strict decoder-to-image timestamp contract supplies the expected zero mapping; startup position is never used to invent an offset. Eleven CPU regressions cover timing, provider identity, manifest/payload validation and IPC failure cleanup.

Preparation published six frames in two segments over decoder range 2057/24000…8063/24000, using 199,070,297 logical bytes. Both processes selected exact decoder PTS 5060/24000 as `prepared-enhanced` and 13068/24000 as `original` outside coverage. Undoing the observed −238944/24000 packet offset recovers the corresponding original-file frames. The second process reused both segments, processed zero frames and preserved every manifest and payload hash. The bypass origin process, both Prepared processes and both source-guard processes exited.

These first six source frames are exactly black: decoded 10-bit limited-range Y=64, Cb=Cr=512 throughout. Every cached payload matches the expected Float32 RGBA `(0,0,0,1)` hash. The result therefore establishes nonzero-start timing and cache wiring with the real neural configuration; it adds no varied-scene image-quality or temporal-reconstruction evidence. Cache pixels were verified in both phases before temporary payload storage was removed; committed manifests remain archived.
