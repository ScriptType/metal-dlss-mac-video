# Native HDR output color audit

The M3 native output controls identified two defects in the former mpv/macvk path: a linear HDR target lost its peak metadata and defaulted to 203 nits, and its float Metal layer retained HDR metadata created for the preceding PQ presentation. A public metadata control reversibly changed compositor output when its optical scale changed from 1 to 203. The targeted native fix now preserves the range and assigns consistent float units after swapchain recreation. Ten metadata transitions pass; a final comparison of compositor pixels with stable window visibility remains open.

The original [isolation evidence](evidence/m3-native-hdr-color-audit.json), published in `38d696a`, preserves the successful controls, the failed original-object restore, exact source and binary hashes, capture timing, and report/payload checksums. All three diagnostic hosts exited successfully with unchanged player, mpv, libplacebo, MoltenVK and shared-engine binaries. The isolated host changed between control builds; each binary is recorded separately.

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

## Native fix and verified scope

The [implementation evidence](evidence/m3-native-hdr-color-fix.json) records the final mpv sources published as `ae579755614cd8a0edf7c6f9d94c0095c7d26216`. Captures used a working tree containing those exact sources before the commit; publication did not rebuild the binaries. The final `libmpv.2.dylib` SHA256 is `4859ba6b0caafa2c7f26bfe6889ae5d1db9c5792cd71503dace6da9bd854ef25`.

The macvk external-color callback preserves a linear BT.2020 target's supplied range while retaining Vulkan's normal color-space and RGBA16F selection. It completes pending recreation with `pl_swapchain_resize(0,0)`, validates the actual layer format/color space/EDR contract, then assigns public HDR metadata with `opticalOutputScale = 203`. That value comes from the source call; `CAEDRMetadata` has no public scale getter. Actual layer properties and target peak are recorded independently. Default linear output therefore reaches Core Animation with source range and defined optical units; it no longer acquires an automatic 203-nit target cap. Explicit user target settings retain their normal meaning. No pass-through swapchain, alpha conversion or swizzle was added.

The ordering follows Apple's requirement to set [`edrMetadata` before `nextDrawable`](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata). The pinned libplacebo resize path creates the swapchain and image wrappers without acquiring a drawable; an unchanged swapchain only takes its mutex. Drawable acquisition follows later in frame start. The renderer retains the layer and metadata under Objective-C manual reference counting and performs a short explicit Core Animation transaction. It makes no synchronous AppKit call per color update and holds no Core Animation lock across Vulkan or main-queue calls. Screen/profile/backing callbacks invalidate a locked revision and request redraw. Allocation/contract failures cannot claim a configured external HDR target.

The successful metadata-only sequence selects exactly 20 seconds from PQ, HLG and SDR sources, then resizes and restores the same float frame. Each enhancement uses real NR at 32×24; this remains an instrumentation shape.

| Observed path | Actual layer / target | Check |
| --- | --- | --- |
| Original PQ | ITUR2100 PQ, 1000 nits | Fresh native HDR metadata after returning from float output |
| Original HLG | ITUR2100 PQ, 1000 nits | This MoltenVK selection converts HLG to a PQ target; metadata is refreshed |
| Original SDR | ITUR709, 203 nits | HDR metadata is nil |
| Enhanced PQ | RGBA16F, extended-linear BT.2020, 1018.656982 nits | Full output peak retained; return reproduces the exact `f84a…ff3fe2` source export |
| Enhanced HLG | RGBA16F, extended-linear BT.2020, 1089.223755 nits | Full output peak retained |
| Enhanced SDR and resize | RGBA16F, extended-linear BT.2020, 203 nits | Drawable changes 2120×1048 → 1680×1000 → 2120×1048; all three exports are byte-identical |

All ten phases passed and the process exited cleanly with unchanged binaries. Many transition phases were occluded, so they establish native state, source bytes and lifecycle behavior. They do not establish compositor brightness, physical luminance or scanout timing. Multiple-display/profile behavior still needs broader runtime qualification.

The evidence retains every excluded attempt. Two early compositor runs became occluded; a later run passed its original weak visibility check but its title-free window inventory showed a global desktop/Space translation. The final guarded binary's capture moved from global x=180/visible before SCK to x=−1683/occluded afterward and is rejected by the stronger check. The source of that movement is not inferred. Two separate harness errors are also preserved: requesting a third lease under a two-lease limit, and casting an in-memory `[CGFloat]` resize value to `[Double]`. The corrected metadata sequence passes. None of these files is presented as a passing final compositor comparison.

## Reproduction

With the shared engine and current mpv build present, compile the diagnostic host and run the metadata transitions in an available GPU window:

```sh
bash scripts/build-hdr-native-color-probe.sh
python3 scripts/test-hdr-native-color.py --transition-control \
  --output artifacts/native-color-transitions-new
```

A later compositor check additionally needs screen-capture access already granted and a stable, visible desktop throughout the three phases:

```sh
bash scripts/build-hdr-capture-probe.sh
python3 scripts/test-hdr-native-color.py --output artifacts/native-color-target-new
```

The current wrapper checks actual visibility and identical global window/display/backing geometry before and after every SCK capture. It rejects a Space transition without repeatedly forcing the window forward. It refuses existing output paths and never requests screen-capture permission. The historical `--metadata-control` and `--scale-control` results above belong to the recorded pre-fix binaries; the native fix now owns and refreshes those metadata values during redraw.

Seven capture-parser CPU tests and the isolated mpv/diagnostic-host builds pass. Raw source, report and payload hashes remain available in the implementation evidence. This native output gate is separate from the unsupported macOS sample-buffer PiP route and from physical display qualification.
