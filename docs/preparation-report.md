# Preparation report — 2026-09-09

This records the local preparation session on Apple M3 with 16 GiB unified memory, macOS 26.5. Xcode 26.6 supplies Swift 6.3.3 and the downloaded Metal toolchain. It is a development baseline, not the plan's final acceptance report.

## Prepared

- Public root repository and an MLX-DLSS fork, with the plan preserved unchanged.
- Four source submodules based on the plan's exact commits and three local reference checkouts. The MLX-DLSS fork adds a metadata-only entry recognizing the signed NR DLL hash.
- Python 3.12.14 environment, locked Python packages, Rust 1.98.0, Tailwind 4.3.3, and native build prerequisites.
- Missing Xcode components repaired/installed. System `xcode-select` and global Git identity were not changed; the project uses the GitHub noreply identity.
- Source-built MLX CLI and app, mpv/libmpv, libplacebo 7.371.0, Erika C ABI library, native demo, and VideoToolbox/Metal import diagnostic.
- Native original-playback harness and JSON Metal/CoreVideo diagnostics.
- Three extracted model packages, checksummed source archives, the DLSS SR source library, synthetic video and numeric HDR fixtures.
- Bootstrap, build, verification, model smoke and publication-audit scripts, and a hosted CI workflow.

Build tools observed: CMake 4.4.3, Meson 1.12.0, Ninja 1.13.2, Homebrew FFmpeg/full 9.0.1, MoltenVK 1.4.2, shaderc 2026.3, Vulkan loader/headers 1.4.357.0, uv 0.12.10. Homebrew mpv/libplacebo remain installed, while the development mpv build links the separately built pinned libplacebo 7.371.0. Erika builds its own FFmpeg 8.1.2 and subtitle dependencies.

## Completed checks

| Check | Result | Local evidence |
|---|---|---|
| Standalone harness build and GPU test | Passed | `artifacts/project-checks.log` |
| Metal RGBA16F write/readback | Preserved `[0, 0.125, 1, 4, 16]` after command completion | `artifacts/gpu-report.json` |
| AVFoundation HDR10 decode | `x420`, two planes, BT.2020/PQ, mastering and content-light metadata retained | `artifacts/hdr10-decode.json` |
| AVFoundation HLG decode | `x420`, two planes, BT.2020/HLG tags retained | `artifacts/hlg-decode.json` |
| Erika VideoToolbox → Metal import | P010 → R16Unorm/RG16Unorm; 1000-nit mastering, MaxCLL 1000, MaxFALL 400 | `artifacts/erika-metal-import.log` |
| mpv existing tests, pinned libplacebo linked | 36 passed | `artifacts/mpv-tests.log` |
| libplacebo existing tests including Vulkan | 15 passed | `artifacts/libplacebo-tests.log` |
| MLX-DLSS core tests | 121 passed | `artifacts/mlx-core-tests.log` |
| Python model extraction tests | 25 passed | `artifacts/model-tools-tests.log` |
| NR image | One 320×192 input processed | `artifacts/nr-smoke.json` |
| NR temporal video | Three input/output frames, VideoToolbox motion | `artifacts/nr-video-smoke.json` |
| Frame generation | Three input frames → five output frames at 2× | `artifacts/fg-video-smoke.json` |
| RTX VSR | 320×192 → 640×384 image | `artifacts/vsr-smoke.json`, `artifacts/vsr-smoke.png` |
| Download/model integrity | Locked source and output hashes verified | `artifacts/models-verify-downloads.log` |
| Fresh model regeneration | Repeated extraction produces identical locked hashes; tensor payloads unchanged by header canonicalization | `artifacts/models-fresh-reproduction.log` |
| NR DLL follow-up | Downloaded original passes NVIDIA signature verification; exact upstream reference fails. Both contain identical 147,695,410-byte weight resources and 153 packed tensors. | [Verification report](nr-dll-verification.md), `artifacts/dll-audit/` |

Model runs were tiny and included startup/compilation overhead. No sustained throughput, final image-quality result, NVIDIA parity result, or M5 performance claim follows from them. The GPU test verifies extended-range storage; it does not validate colour conversions or an HDR display.

## Remaining boundaries

- DLSS SR is optional and deferred. If revisited, model preparation requires a one-time CUDA capture on an NVIDIA GPU. The SDK library and converter are ready; no `.srmodel` was generated.
- NR weight equivalence to upstream is verified. NVIDIA runtime-output parity remains unmeasured.
- HDR enhancement, the shared scheduler/C ABI, mpv/Erika neural adapters, cache, finished UI and target-machine benchmarks are implementation work. The current harness plays the original through AVFoundation; the upstream neural video exporter is SDR.
- The app is a local ad-hoc signed development build. Notarization, distributable dependency packaging and app-store preparation are outside this baseline.
- The window was launched, but macOS denied window screenshot capture. No claim of visually verified UI/HDR display accuracy is made.

See [implementation handoff](implementation-handoff.md) for the next concrete code changes. All build/model/media artifacts remain local; public source contains manifests and reproducible commands.
