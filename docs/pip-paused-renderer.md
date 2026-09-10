# Paused sample-buffer renderer check

The public AVFoundation renderer returned the expected float image while its rate-zero clock was 20 ms or 5 ms behind the sample PTS on the tested M3/macOS 26.5. The suspected missing paused frame was not reproduced, so this experiment does not justify changing the application's clock policy.

```sh
source scripts/env.sh
mkdir -p artifacts/pip-paused-renderer
swiftc -swift-version 6 -parse-as-library tools/HDRPiPProbe/PausedRenderer.swift \
  -o artifacts/pip-paused-renderer/PausedRenderer
artifacts/pip-paused-renderer/PausedRenderer artifacts/pip-paused-renderer/report.json
```

The standalone probe requires macOS 14.4 or later and an interactive display. It attaches an `AVSampleBufferDisplayLayer` to a native window and enqueues two synthetic 64×48 linear BT.2020 RGBA16F images. Each sample retains an exact PTS and 1/30-second duration. After a 500-ms hold it calls the public `displayedPixelBuffer()` getter, moves the timebase to the selected PTS, then checks the returned float pixel identity again. No neural engine, second audio output or `DisplayImmediately` attachment is involved.

The [M3 evidence](evidence/m3-pip-paused-renderer.json) records both observations, exact binary16 pixel bits, source/binary/report hashes and clean process exit. Red and blue pixel identities matched both before and after reanchoring. The getter also returned the last image immediately after a completed removal flush; the check does not infer framework retention or physical removal from that callback.

This is an observation of paused renderer behavior on this OS, not a guarantee that arbitrary future samples display immediately. It does not exercise the system PiP window, measure scanout or acoustic synchronization, or establish physical HDR accuracy. The native streaming consumer retains separate lifetime, clock-gap, seek and unsupported-format checks.
