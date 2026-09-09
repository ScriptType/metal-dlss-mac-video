# Native HDR presentation

`HDRMetalView` is the native development surface. `NativeHDRPlayback` feeds it decoded SDR, PQ and HLG originals; this controller is a video-only harness. Selected-core audio, seeks, track controls and neural playback remain separate integration work.

## Buffer and colour policy

The original bypass boundary is an evaluated `MLXHDRFrame.original`: linear BT.2020 RGB in absolute cd/m². `MLXPixelBufferWriter(halfOutput: true)` packs that image into RGBA16F without RGB clipping. `HDRSurfaceFrame` binds its CoreVideo Metal texture directly, retains the original and packed owners through presentation completion, and carries rational time/duration, source/frame/generation identity and geometry. No sRGB proxy is involved in bypass.

The presenter applies pixel aspect in source coordinates, then the retained affine transform and crop, then aspect fits the result into the drawable. Letterbox pixels are opaque black. A working texture is immutable while any consumer retains it. External producers may supply an `MTLSharedEvent` and readiness value; the presentation command waits on the GPU before sampling.

The fragment shader performs these operations once:

1. Divide absolute BT.2020 nits by reference white, normally 203 cd/m². A value of 1 denotes the display's current SDR white, whose physical luminance depends on user brightness and display mode.
2. Convert linear BT.2020 D65 to linear Display P3 D65. Preserve negative and extended components for colour-managed layer interpretation.
3. Apply a chromaticity-preserving shoulder against current display EDR headroom `H`. With `K = min(1, 0.75H)` and RGB maximum `P`, values below `K` are unchanged. Above it, scale the RGB vector by `(K + (H-K) * (1-exp(-(P-K)/(H-K)))) / P`. This explicit display adaptation is independent of the model proxy.
4. Store RGBA16F in a `CAMetalLayer` configured as extended-linear Display P3 with `wantsExtendedDynamicRangeContent = true`. Core Animation handles the selected display's colour interpretation. The layer has no additional media tone-mapping metadata, so there is no second application tone mapper.

Current, potential and reference EDR headroom are recorded separately. Screen changes and backing-scale changes refresh the surface configuration. Physical gamut and luminance limits still apply; pre-display captures retain the original source values. Apple documents the required [extended-linear layer configuration and application tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping).

## Run and capture

Use the Xcode toolchain selected by `scripts/env.sh`; the default Command Line Tools toolchain may be too old for the pinned MLX dependency.

```sh
source scripts/env.sh
scripts/build-harness.sh
.build/debug/HDRHarness assets/test-clips/hdr10-30.mp4 \
  --frames 60 --capture-dir artifacts/hdr-display/pq \
  --capture-every 30 --report artifacts/hdr-display/pq-report.json \
  --exit-after-playback
.build/debug/HDRHarness assets/test-clips/hlg-60.mp4 \
  --frames 120 --capture-dir artifacts/hdr-display/hlg \
  --capture-every 60 --report artifacts/hdr-display/hlg-report.json \
  --exit-after-playback
```

`--headless --headroom 4` runs the same render shader into an offscreen RGBA16F texture at source dimensions without opening a window. Its headroom is a test parameter, not a detected display capability. Captures introduce an intentional GPU-to-CPU readback after render completion; ordinary presentation does not read pixels back.

Each capture contains tightly packed little-endian binary16 RGBA buffers and one JSON sidecar. `original` records absolute linear BT.2020 nits before display mapping; `display` records extended-linear P3 relative to SDR white after mapping and geometry. The sidecar includes PTS/duration numerators and denominators, geometry, source tags, colour units, dimensions, sample pixels, component extrema and nonfinite counts. Its filenames include generation, frame index and rational PTS.

```python
import json
from pathlib import Path
import numpy as np

sidecar = Path("artifacts/hdr-display/pq/g1-f0-pts0_15360.json")
record = json.loads(sidecar.read_text())
for buffer in record["buffers"]:
    pixels = np.fromfile(sidecar.parent / buffer["file"], dtype="<f2")
    pixels = pixels.reshape(buffer["height"], buffer["width"], 4)
    print(buffer["units"], pixels[..., :3].min(), pixels[..., :3].max())
```

## Validation boundary

`HDRSurfaceTests` exercises completed Metal rendering, 10,000-nit original retention, negative P3 components for saturated BT.2020, dark values, highlight mapping, rational capture metadata, crop and rotation. The run report records actual device/OS, source/presentation sizes, completed frame counts, GPU time, captures and display configuration.

These checks establish buffer interpretation and submitted native rendering. Physical display accuracy requires inspecting the PQ/HLG clips on an HDR/EDR display under a recorded brightness/preset configuration, ideally with a colourimeter. A successful offscreen run, drawable completion, or 8-bit screenshot alone does not establish physical luminance, gamut accuracy or temporal visual quality.
