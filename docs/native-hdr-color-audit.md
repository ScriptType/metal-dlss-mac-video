# Native HDR output color audit

The M3 native output controls identify two defects in the measured mpv/macvk path: a linear HDR target loses its peak metadata and defaults to 203 nits, and its float Metal layer retains HDR metadata created for the preceding PQ presentation. A public metadata control reversibly changed compositor output when its optical scale changed from 1 to 203. No production fix is included in this checkpoint.

[Compact evidence](evidence/m3-native-hdr-color-audit.json) preserves the successful controls, the failed original-object restore, exact source and binary hashes, capture timing, and report/payload checksums. All three diagnostic hosts exited successfully with unchanged player, mpv, libplacebo, MoltenVK and shared-engine binaries. The isolated host changed between control builds; each binary is recorded separately.

## Fixed frame and measured controls

All nine captures use the same paused PQ fixture frame at exactly `20,000,000/1,000,000` seconds, real NR processing at 32×24, strength 1 and reference white 203. This resolution is instrumentation only. The retained 320×192 RGBA16F export has the same SHA256 in every phase and in the preceding PiP buffer isolation: `f84a0325c5b1bd166498968bb8f09164a63ee73e5207f8b928eda0e466ff3fe2`. Each process retained its generation/revision and two total inference submissions throughout its controls.

| Control | Fixed conditions | Observation |
| --- | --- | --- |
| Target peak automatic → 1000 → automatic | Same retained frame and layer metadata | Actual target peak changes 203 → 1000 → 203. The middle SCK capture changes 5,465,406 encoded components; the final capture is byte-identical to the first. |
| Existing metadata → nil → same existing object | Target peak 1000 | Clearing metadata brightens the captured image. Restoring the property does **not** restore the first capture. This control establishes a change, but fails the reversible return check. |
| Fresh metadata optical scale 1 → 203 → 1 | Target peak 1000; metadata min 0/max 1018.656982421875 | The middle capture changes 5,489,409 encoded components and contains RGB values above one. The final capture is byte-identical to the first. |

The last control constructs each metadata object with the public `CAEDRMetadata.hdr10(minLuminance:maxLuminance:opticalOutputScale:)` API. It requests new native draws by setting `video-pan-x` to 0.0001 and back to 0, restores exact geometry before capture, and records each call's host time. Source pixels and inference count remain unchanged. These fresh-object controls differ from the original-object restore and do not erase that failed result.

SCK captures only the diagnostic host's verified, actually visible window. The layer is RGBA16F, extended-linear BT.2020 and EDR-enabled throughout. Capture stride, alpha, ICC, timing and headroom are retained. The opaque video comparison region is `(190,66,1740,1044)` inside the 2120×1112 window capture. ICC conversion uses only finite opaque RGB values within `[0,1]`; the scale comparison includes 62,801 pixels and explicitly excludes 1,753,759 extended pixels. No HDR transfer extrapolation, panel-nit estimate or physical calibration follows from these files.

## Source path

`vf_metal_hdr.m:217` divides absolute nits by 203 and publishes linear BT.2020 with the source peak at lines 687–690. This matches libplacebo's `PL_HDR_NORM` convention: unity is 203 nits. The float import does not perform another transfer decode.

In the measured `context_mac.m:89` configuration, macvk has no preferred-color, reference-white or external-color callback. Consequently automatic reference white returns zero; it does not overwrite the input with a system reference-white value. `vo_gpu_next.c:1476` selects a linear source hint, but libplacebo's Vulkan `set_hdr_metadata` returns at `swapchain.c:351` because it tests transfer type alone. It returns before storing the supplied peak in the swapchain's color description. An unspecified linear target then infers 203 nits. Runtime `video-target-params` confirms that range loss against the 1018.656982-nit source.

MoltenVK 1.4.2 creates HDR metadata with optical scale 1 for the preceding PQ swapchain. Its [BT.2020 linear branch](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.2/MoltenVK/MoltenVK/GPUObjects/MVKSwapchain.mm#L503-L505) changes the layer color space and enables EDR without clearing that metadata. The captured float layer still has the previous nonnil object. The installed public `CAEDRMetadata.h` documents the float relationship `C = opticalOutputScale × y`; thus scale 1 does not describe the producer's unity = 203 convention. The fresh-scale control establishes an actual compositor response to that mismatch, independently of the nominal target-peak control.

The recorded mpv PNG screenshots are a separate diagnostic. `vo_gpu_next.c:1959` clears the linear source peak before rendering screenshots to a separate UNORM target. They are not raw native swapchain pixels and cannot replace the SCK/exported-buffer evidence.

## Reproduction and implementation boundary

With the existing shared engine and mpv build present, run sequentially in an available GPU window:

```sh
bash scripts/build-hdr-native-color-probe.sh
bash scripts/build-hdr-capture-probe.sh
python3 scripts/test-hdr-native-color.py --output artifacts/native-color-target-new
python3 scripts/test-hdr-native-color.py --output artifacts/native-color-metadata-new --metadata-control
python3 scripts/test-hdr-native-color.py --output artifacts/native-color-scale-new --scale-control
```

The wrapper refuses existing output paths and never requests screen-capture permission. The helper uses only public APIs and the current frame-export ABI; it creates no AVKit renderer or PiP controller. Seven existing capture-parser CPU tests passed, both isolated helpers compiled, and all payload/report hashes were verified.

A platform color handler is the preferred next implementation candidate: preserve the linear target's supplied range, explicitly configure float optical units, and clear stale metadata during source/transfer transitions. Its swapchain format, alpha, recreation order and display-update behavior must be verified before adoption. Clearing metadata alone does not define an absolute HDR mapping. The source/export contract should remain unchanged; native output needs one defined display mapper. This gate is separate from the unsupported macOS sample-buffer PiP route and from physical display qualification.
