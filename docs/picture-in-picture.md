# Processed HDR picture-in-picture

The native app has an opt-in diagnostic PiP consumer of completed RGBA16F frames on the tested Apple M3 with macOS 26.5. It reuses the existing mpv decoder, enhancement, audio and selected presentation surfaces. Actual AVKit entry, streamed delivery, minimized-window progress, pause, seek, comparison, subtitle rejection and teardown pass the bounded integration check below. Roadmap #17 remains open: physical HDR brightness and sustained presented A/V synchronization are unqualified, so ordinary app PiP stays hidden and disabled.

Apple provides the sample-buffer content-source initializer and playback delegate on macOS 12 and later. This standalone probe requires macOS 26 because it uses the current asynchronous asset-reader API. It uses [AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller) with [AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer); no private PiP API or display capture is involved.

## Run the standalone probe

Build the shared engine using the repository's normal build first. The probe script compiles a separate app and records its binary, source, header, shared-library and metallib hashes. It does not rebuild shared playback binaries.

```sh
bash scripts/build-pip-probe.sh
artifacts/pip-probe/HDRPiPProbe.app/Contents/MacOS/HDRPiPProbe \
  --source assets/test-clips/hdr10-30.mp4 \
  --model models/neural-rendering/NeuralRendering.dlssmodel \
  --format float --report artifacts/pip-probe-float.json
```

Use `--format pq` for the explicit P010 conversion experiment. Omitting `--model` selects engine bypass and cannot demonstrate enhanced output. Run measurements sequentially without another GPU workload. The probe uses the first decoded image and supports even dimensions through 1080p; the validated fixture is unrotated, square-pixel PQ/BT.2020 with left-sited chroma.

The probe retains the exact completed engine lease through PiP. The source sample's output PTS, or sample PTS if needed, remains unchanged in the sample buffer and paused control timebase. Missing duration uses the next decoded image's exact PTS interval, with provenance in the report; it does not assume nominal frame rate. The interval is a held-frame display interval, not an assertion that an omitted container duration existed. It is never resubmitted to the temporal model for redraw, resize or restoration.

Public start/stop/restore and render-size delegates are recorded. The source window is resized during PiP; this does not count as resizing the system PiP window. Playback requests are recorded against a paused reference only. At teardown the display renderer flushes before the engine lease is released, the session is closed, idle is observed and the session is destroyed off the main thread. Application termination cannot bypass that drain.

## M3 result

The [compact evidence](evidence/m3-pip-held-frame.json) preserves exact source timing, conversion metrics, lifecycle events, hashes and the initial duration-validation failure. Both successful cases used one actual neural output (`contentKind=2`), source 320×192, processing 32×24, strength/colour strength 1, reference white 203 nits and maximum luminance ratio 2. Submitted/completed counts remained 1 throughout; exact PTS was 0/48000 and the next decoded interval was 512/15360. Both processes exited 0.

| Presentation surface | Public PiP lifecycle | Maximum / mean / RMS numeric error, nits | Interpretation |
| --- | --- | --- | --- |
| RGBA16F, linear BT.2020, values divided by 203 | Supported, possible, start, stop, restore; renderer rendering | 0.77344 / 0.05853 / 0.09226 | Float normalization round trip only; AVKit physical reference-white mapping is unverified |
| P010, PQ, limited range, BT.2020 NCL, 4:2:0 | Supported, possible, start, stop, restore; renderer rendering | 1112.93874 / 7.25421 / 25.62027 | Decode of the actual quantized/subsampled surface against the clipped input domain; includes chroma loss and 10-bit quantization |

Input RGB components ranged from 0.50684 to 2492 nits. Neither case contained negative or above-10000-nit components; PQ clipped zero components. PQ clamps those domains explicitly when present. Each experiment performs one full-frame CPU readback and one CPU surface write; framework-internal copies are unmeasured. These are probe costs, not the proposed production path.

Both cases produced a single 640×384 render-size delegate value. Actual PiP-window resizing, streamed controls, A/V synchronization, physical luminance/colour and external-display transitions were not measured. Renderer readiness and PiP entry alone cannot establish those properties. The 4:2:0 experiment's large chromatic-edge error disqualifies that conversion as the default path for preserving processed RGB; float transport avoids its subsampling and PQ-clipping loss.

A subsequent float rerun also passed after teardown hardening: renderer flush completed before engine destruction, idle was observed, occupied engine slots reached zero and close/drain took 35.8 microseconds. Its separate report and compiled-input hashes are retained in the same evidence file.

## Optional libmpv frame export

The fork now implements the optional versioned interface in `vendor/mpv/include/mpv/hdr_frame.h`. Resolve `mpv_hdr_export_open`, `mpv_hdr_export_poll`, `mpv_hdr_frame_get`, `mpv_hdr_frame_is_current`, `mpv_hdr_frame_release` and `mpv_hdr_export_close` from the loaded libmpv. This is separate from the ordinary upstream client ABI. The header defines all ownership, status and structure-version requirements.

One exporter per core polls a single selected frame. At most three leases may remain outstanding across exporter reopen; callers may request a smaller bound. Only successful VO draw/flip selection publishes a revision, including paused same-PTS replacement; this boundary is not a physical scanout timestamp. Selection remains active when the host is minimized. Seeking, generation changes, capability changes, exporter close and VO destruction invalidate stale leases. Retained buffers remain readable after core destruction; release every lease before unloading libmpv.

Every poll returns clock/state even when the frame is unchanged, unsupported or the lease budget is full. Native `mach_absolute_time` ticks anchor the measured CoreAudio media time; `clock_sample_span_ticks` reports sampling uncertainty. Convert ticks with `CMClockMakeHostTimeFromSystemUnits`, not mpv's offset `mp_time_ns` epoch. The snapshot distinguishes exact source PTS/duration from player PTS and source-to-player offset, and records user pause, actual core pause and enhancement/cache buffering. Paused video without audio uses its selected PTS at rate zero. A progressing video-only clock remains unsupported.

Normalized float buffers receive immutable linear BT.2020 and extended-linear colour-space tags before publication. The export has no full-frame CPU readback or additional normalization copy. Its lease count does not measure references retained internally by AVFoundation after enqueue: consumers must separately bound that retention, and the existing six-buffer producer pool can stall until those references drain. Original P010 previews, raw Dolby Vision, enabled subtitles and nontrivial geometry return explicit unsupported status. The exporter does not silently composite or reinterpret those frames.

The standalone ABI smoke is `vendor/mpv/TOOLS/hdr-export-probe.swift`. With the shared engine and adapter already built:

```sh
source scripts/env.sh
mkdir -p artifacts/mpv-host
swiftc -swift-version 5 -O \
  -import-objc-header vendor/mpv/include/mpv/hdr_frame.h \
  vendor/mpv/TOOLS/hdr-export-probe.swift -o artifacts/mpv-host/HDRExportProbe \
  -L "$PROJECT_ROOT/artifacts/mpv-build" -lmpv \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/artifacts/mpv-build" \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/.build/debug" \
  -framework AppKit -framework AVFoundation -framework CoreVideo -framework QuartzCore
cp .build/debug/mlx.metallib artifacts/mpv-host/mlx.metallib
artifacts/mpv-host/HDRExportProbe \
  "$PROJECT_ROOT/assets/test-clips/playback/pq-30-30s.mkv" \
  "$PROJECT_ROOT/models/neural-rendering/NeuralRendering.dlssmodel" \
  "$PROJECT_ROOT/artifacts/mpv-hdr-export-probe.json"
```

The [M3 ABI smoke evidence](evidence/m3-pip-exporter.json) records retained float metadata, exact paused comparison without additional inference, seek invalidation, subtitle capability invalidation/resume, a two-lease limit across reopen and buffer lifetime after core destruction. During three seconds with the native window minimized it observed 24 new selected neural frames, 495 audio-clock snapshots, 0.80935 seconds of media advancement and at most two pending producer frames. The sampled host-clock anchor was 46.4 microseconds behind the immediate CoreMedia clock check; its sampling interval spanned 1.25 microseconds. These establish the timestamp domain and bounded exporter behavior, not physical presentation timing or streamed AVKit synchronization.

## Diagnostic app consumer

Enable the consumer only for a diagnostic run. The normal app neither creates an exporter nor attaches the AVKit layer. The optional extension is resolved from the already loaded libmpv; an older core reports unavailable without breaking ordinary playback.

```sh
source scripts/env.sh
npm --prefix apps/controls run build
swift build --product HDRPlayer --jobs 2
HDRPLAYER_ENABLE_PIP=1 .build/debug/HDRPlayer assets/test-clips/player-controls.mkv

# Uses isolated application preferences and the existing built playback binaries.
python3 scripts/test-player-lifecycle-playback.py \
  --scenario pip --output artifacts/player-pip-streaming
```

The runtime and adapter must already be built using the normal repository scripts. The check records the app, libmpv and shared-engine hashes before and after its run and rejects a binary replacement. It enables enhancement at 32×24, disables subtitles before PiP entry and drives the shipped web controls through the existing native worker. It does not build a second decoder, inference session or audio renderer.

`MPVFrameExport.swift` polls the selected-frame interface from the native client worker. Its mailbox coalesces delivery to one latest snapshot and one scheduled main-thread callback; an unchanged clock poll retains an undelivered frame of the same revision. New generations or unsupported formats invalidate it. `PictureInPictureController.swift` retains at most one pending and one submitted lease, checks native lease validity before enqueue, and binds exact source PTS/duration to the player's timeline. A zero source offset preserves the original rational PTS without rescaling; nonzero offset conversion and rounding are reported separately.

The display renderer receives the completed, tagged RGBA16F CVPixelBuffer directly. There is no consumer CPU pixel readback, P010 conversion or normalization pass. Renderer readiness controls enqueue, and each replacement flushes queued media with an asynchronous completion before the previous submitted lease is released. Generation changes and unsupported images clear the displayed image as well. A successful enqueue is not treated as renderer completion. Native CVPixelBuffer retention and the existing six-buffer producer allocation threshold prevent premature reuse; producer allocation can stall rather than grow unbounded. AVFoundation's internal retained-reference count is not exposed by a public API, so the report distinguishes measured exporter/app references from that allocation bound.

`PiPCoreClock.swift` updates the CoreMedia timebase on every worker snapshot before the main-thread mailbox. It uses native host ticks and measured media time, including rate-zero Adaptive holds and user pause, without waiting for the 120-ms JSON state poll. Stale host samples cannot overwrite a newer anchor. The main thread still owns AVKit enqueue and can stall during AppKit animations; a continuing timebase does not guarantee continuing image presentation. Clock correction and snapshot-age metrics therefore describe timebase binding only.

Clock diagnostics also distinguish `maximumInterSnapshotReceiptGapSeconds`, measured between monotonic worker receipt times, from `maximumValidSnapshotHostGapSeconds`, measured between distinct accepted native clock timestamps. A fresh sample can have low age after a long worker stall. Invalid clock samples count as receipts but do not advance the valid-host watermark; stale timestamps never move either watermark backward. These maxima cover completed intervals, not an ongoing stall since the last receipt. At most 100 intervals above 50 ms receive detailed state records; that threshold limits logging and does not change playback policy. The [CPU gap evidence](evidence/pip-clock-gap-cpu.json) validates these definitions with synthetic timestamps. The earlier 18-check app capture predates these metrics and cannot establish its inter-snapshot gaps or qualify continuous PiP synchronization.

PiP playback delegates route play/pause and skip requests through the same native commands as the app. Skip completion waits for a supported replacement generation or a bounded failure timeout. The source window restores through AppKit. Termination stops active PiP, waits for renderer flush, releases consumer leases, closes the exporter, and then destroys the existing mpv core. The lifecycle recorder verifies that order in the actual app process.

Request state preserves a stop requested during asynchronous startup, clears pending requests after startup failure and completes late seek callbacks immediately during shutdown. A failed renderer flushes and keeps PiP unavailable until restart; an unchanged paused frame cannot silently repopulate an emptied renderer because its selected revision was already exported. Six CPU request-ordering scenarios cover these cases, and the hardened app reran the 18-check integration successfully. The separate [paused renderer probe](pip-paused-renderer.md) did not reproduce a missing frame with a held clock 5–20 ms behind its sample, so it prompted no clock-policy change.

### Current stream gate

Diagnostic opt-in alone does not enable entry. The exporter must report a supported current snapshot, its audio/paused clock must be valid, an actual current frame must have been enqueued and AVKit must report PiP possible. A cached system-possible flag cannot enable entry after a generation or subtitle transition without a new frame.

| Input or transition | Diagnostic consumer behavior |
| --- | --- |
| Completed normalized RGBA16F with valid exact timing and audio clock | Available after successful enqueue and public AVKit possibility; PQ fixture verified |
| Paused supported frame | Held timebase, retained same-PTS replacement; verified without additional inference |
| Seek generation with raw P010 preview | Clear stale imagery and wait for the matching float replacement; verified |
| Raw P010 Original comparison | Report unsupported and exit PiP; enhanced same-PTS comparison can re-enter |
| Prepared cache miss returned as normalized RGBA16F Original | Keep PiP active with Original provenance and the same exact native PTS/generation; verified |
| Enabled subtitles, including secondary subtitles | Report that this export omits subtitles and stop PiP; primary subtitle enable/disable verified |
| Raw Dolby Vision | Unsupported; native gpu-next playback remains the colour-processing path |
| Crop, rotation or non-square pixels | Unsupported geometry |
| Running video without a supported audio clock | Unsupported; a paused selected frame can provide a rate-zero clock |
| Missing exact duration, unsupported format or failed renderer | Explicit unavailable state; no silent reinterpretation |

The layer is attached behind the existing native video child view, not a web video or display capture. It exports pre-composition video; mpv subtitles and OSD are not included. The interface label and error state remain diagnostic until the outstanding qualification gates pass.

### M3 app evidence and remaining gates

The [compact consumer evidence](evidence/m3-pip-consumer.json) records all 18 passed DOM checks, unchanged binary hashes, native subtitle colour, exact timing, clock metrics, renderer events and teardown order. The actual app enqueued 14 frames, progressed while the source window was minimized, paused, returned from an unsupported Original comparison to the same enhanced source PTS without additional inference, sought to 1.4 seconds in a new generation, stopped for subtitles, recovered after their removal and terminated while PiP was active. The process exited 0. Exporter leases peaked at three, pending/submitted consumer leases stayed at one each and both were zero after final renderer flush, before native core destruction.

The worker timebase recorded 544 updates, including 504 holds, with maximum anchor correction 17.374 ms and maximum snapshot age 0.636 ms. These values do not measure acoustic output, display scanout or AVKit's internal presentation delay. The sample PTS after the paused seek remained exactly 1400000/1000000, without rounding. The test confirms bounded functional delivery and correct source identity; its short clip does not establish sustained PiP cadence or the playback A/V target.

Nine CPU clock/mailbox/gap checks run through `scripts/test-player-lifecycle.sh`, also called by `scripts/check.sh` and CI. They cover pause/seek anchors, unsupported and invalid clocks, stale host samples, 2,000 coalesced worker snapshots while the main actor is blocked, closed-consumer behavior, distinct receipt/native-host gaps and bounded diagnostic storage. They do not create a renderer or qualify a physical clock.

### Active quality changes

The [M3 reconfiguration evidence](evidence/m3-pip-reconfiguration.json) records an actual active PiP run that changed neural processing from 32×24 to 160×96 and back through the shipped controls. All 11 functional checks passed, the binary hashes stayed unchanged, and PiP remained active at every recorded transition observation. The replacements established exporter epochs 20→28→36 and continued delivery, with 17 total enqueues and at most two exported leases. The final paused source PTS was 1067000/1000000; renderer flush released all pending/submitted leases before core destruction.

```sh
python3 scripts/test-player-lifecycle-playback.py \
  --scenario pip-reconfigure \
  --source assets/test-clips/playback/pq-30-30s.mkv \
  --output artifacts/player-pip-reconfigure
```

The two quality changes exposed completed worker receipt gaps of 106.172 ms and 124.398 ms, with valid-host gaps of 106.178 ms and 124.405 ms. The second interval followed a running timebase sample and ended at an unsupported-frame snapshot, when the existing consumer policy held the timebase. No intermediate sample establishes what AVKit physically displayed during that interval. The largest receipt gap, 196.019 ms, occurred during startup, while maximum snapshot age stayed below 0.270 ms. Maximum anchor correction was 20.689 ms before either quality change. These measurements establish why freshness, delivery cadence and clock correction must remain separate; they do not qualify uninterrupted presented A/V synchronization. No clock policy changed for this capture.

Keep #17 open until sustained presented A/V behavior, audio-device changes, physical HDR/reference-white mapping and external-display transitions are verified. The earlier consumer and reconfiguration tests use DOM transport controls; the separate system-control check below exercises actual PiP buttons and the PiP window. Float numeric preservation and exporter bounds remain separate evidence from the unmeasured presentation properties.

### Prepared cache transitions

The app consumer also passes a bounded Prepared case using the sustained 320×192, 30 fps PQ source and processing at 160×96. Run with existing stable app/adapter/shared binaries:

```sh
source scripts/env.sh
python3 scripts/test-player-pip-prepared.py \
  --output artifacts/player-pip-prepared-run

# Reuse the retained seed only when its source/provider/model/settings match.
python3 scripts/test-player-pip-prepared.py --reuse-seed \
  --cache-directory artifacts/player-pip-prepared-run/cache \
  --output artifacts/player-pip-prepared-repeat
```

A fresh run prepares exactly 180 neural frames in three 60-frame segments, covering the first six seconds with eight-frame preroll and a 1 GiB capacity. The seed core closes before the native app opens the same cache. Reuse verifies source hash/size/stream, model, geometry, effect/colour settings, exact timing inventories and every pixel payload checksum; the existing cache-open/hit path checks the current provider and implementation identity. A changed provider version explicitly rejects the old seed. The script never silently rewrites its identity.

The [Prepared PiP evidence](evidence/m3-pip-prepared.json) records 12 passed app checks and unchanged binaries. The app entered PiP at a cached one-second frame, streamed across the two-second segment boundary, paused, sought to an uncached eight-second frame and returned to the same cached one-second PTS. The miss remained valid normalized RGBA16F with **Original** provenance (`contentKind=1`), exact PTS 8000000/1000000 and generation 4. PiP stayed active. Return to cached enhancement produced `contentKind=4`, exact PTS 1000000/1000000 and generation 5. No preparation job ran in the app (`processedFrames=0`), and all cache pixel payloads remained unchanged.

The app enqueued 42 frames; exporter leases peaked at two, consumer pending/submitted leases stayed bounded at one each, and final renderer flush released both before native teardown. The seed produced 180 frames in 17.05 seconds; that preparation duration is separate from playback. The final clock metrics were 19.018 ms maximum anchor correction, 0.056 ms maximum sample age, 172.551 ms maximum receipt gap during startup and 35.259 ms maximum valid-native-host gap. These are observed clock-binding intervals, not physical PiP presentation or acoustic synchronization.

The evidence retains the initial incorrect test expectation that a cache miss would exit PiP. Valid float Original fallback required no product restriction. It also retains the old-seed rejection after the compiled core version changed; one new seed was then prepared against the current provider. Raw P010 Original comparison still exercises the separate unsupported-format path in the 18-check consumer scenario. The lifecycle-hardened app reran those 18 checks successfully before this Prepared capture; both reports remain bound to their measured binaries.

### System PiP controls and window resize

The [M3 system-control evidence](evidence/m3-pip-system-controls.json) records seven actual Accessibility operations on the running `com.apple.PIPAgent`: Play, Pause, both ten-second skip buttons, two window-size requests and Restore. Eight action/state checks and six independent callback/teardown checks passed. The app exited 0, and the app, helper, libmpv and shared-engine hashes stayed unchanged during capture. This is a bounded functional check on the local system PiP implementation.

Build the helper and app before starting the capture; keep playback binaries unchanged until it exits:

```sh
source scripts/env.sh
bash scripts/build-system-pip-accessibility.sh
swift build --product HDRPlayer --jobs 2

# Terminal 1: sets up paused PiP at 20 seconds in the 60-second fixture.
python3 scripts/start-system-pip-check.py \
  --output artifacts/player-pip-system-run

# Terminal 2, after READY: inspect each target afresh and exercise its AX action.
python3 scripts/exercise-system-pip-controls.py \
  --session artifacts/player-pip-system-run

# After Terminal 1 exits, correlate actions with recorded native callbacks/state.
python3 scripts/verify-system-pip-controls.py \
  --session artifacts/player-pip-system-run
```

`SystemPiPAccessibility` is read-only unless given an explicit owner PID/bundle, node path, current match token and action. It uses the existing Accessibility permission, never requests consent or changes OS preferences, and reports only discovered Apple PiP owners. Window titles, static text and unrelated application content are omitted. Inspection records public AX roles, identifiers, supported actions, bounds and whether bounds are settable. Every mutation revalidates the target and requires a single PiP window. The action driver uses identifiers observed in the actual tree, including the Play button's change from `play` to `pause`; an unexpected or ambiguous tree fails explicitly. The helper uses Apple's public [action discovery API](https://developer.apple.com/documentation/applicationservices/1462053-axuielementcopyactionnames?language=objc) and [existing-trust query](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted?preferredLanguage=occ).

The opt-in `pip-system` setup writes an atomic state snapshot every 200 ms and waits at most 120 seconds for an explicit finish marker. It never invokes a playback delegate to simulate a system control. Actual AX Play/Pause produced matching AVKit requests and native pause changes. Backward and forward skip requests established generations 4 and 5 in about 419 ms and 315 ms, respectively. Their PiP source PTS matched the native selected frame exactly at 10100000/1000000 and 20100000/1000000. These intervals end at replacement-frame delivery, not physical presentation or audible output.

The system PiP window changed from 444×245 points to 576×325 after a 564×325 request. Requesting the original size returned 442×245: AVKit applies its own constraints, so the check records requested and actual bounds rather than asserting exact size restoration. Resize kept the paused source PTS, generation and inference submission count unchanged. Only the initial render-size delegate was observed; the actual resize evidence comes from the scoped system window's AX bounds.

Before pressing the actual system Restore button, the diagnostic hook minimized the source window and verified it was no longer visible. Restore invoked the real interface-restoration delegate, stopped PiP and returned the source window to visible, key, active and frontmost state. Renderer flush released the remaining consumer leases before native core destruction. Five frames were enqueued, exported leases peaked at two, and pending/submitted consumer references were zero after flush. The largest completed worker receipt gap was 348.237 ms during a paused hold around restoration; maximum anchor correction was 21.204 ms. These diagnostics do not establish continuous presentation, physical HDR brightness, acoustic A/V synchronization, VoiceOver announcements or behavior on other displays.
