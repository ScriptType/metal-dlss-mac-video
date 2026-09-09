# Development setup

The authoritative feature scope is [the plan](../mac-hdr-player-plan.md). Source submodules start from the plan's exact revisions. The MLX-DLSS fork adds recognition of the verified NVIDIA-signed NR DLL hash; inference and extraction code remain at the plan's baseline.

## Toolchains

- Apple Silicon, macOS 26+, Xcode with Swift 6.2 or later and the downloadable Metal toolchain.
- `scripts/env.sh` selects Xcode for project commands through `DEVELOPER_DIR`; the system `xcode-select` setting is unchanged.
- Homebrew tools are declared in `Brewfile`. `ffmpeg-full` provides `zscale` for actual HDR transfer conversion; ordinary Homebrew `ffmpeg` lacks that filter.
- Python 3.12 and all dependencies are pinned by `uv.lock`. `uv sync --frozen --all-groups` also prepares Core ML conversion tools. Linux-only NVIDIA VFX is read as a ZIP archive, not installed.
- Rust 1.98.0 is pinned in `rust-toolchain.toml`; Erika uses its checked-in `Cargo.lock` and pinned FFmpeg 8.1.2/static subtitle dependencies.
- Tailwind is pinned at 4.3.3 in `apps/controls/package-lock.json`. No remote resources load in WKWebView.
- Homebrew bottles are host tools, not a binary release lock. Their observed versions are recorded in the preparation report. Distributing a standalone player requires a separate dependency-packaging step.

Initial preparation repaired Xcode with `xcodebuild -runFirstLaunch` before downloading `MetalToolchain`. Both commands are available in bootstrap when Metal is missing; no global shell profile was changed.

## Individual commands

```sh
python3 scripts/fetch-sources.py
uv sync --frozen --all-groups
python3 scripts/fetch-models.py
uv run --frozen scripts/generate-fixtures.py
bash scripts/build-harness.sh
bash scripts/build-mlx.sh
bash scripts/build-playback-cores.sh
bash scripts/check.sh
bash scripts/test-cores.sh
```

To package the upstream experimental app as well:

```sh
bash -c 'source scripts/env.sh; vendor/MLX-DLSS/scripts/build-native-app.sh'
```

`artifacts/HDR Player.app` is an ad-hoc signed development app, not notarized. It uses AVFoundation for original playback while mpv and Erika integrations are pending. Cmd+O opens a local file, Cmd+Q quits. The controls provide open/play/pause. MKV, advanced subtitles, and final playback features belong to the adapter stage.

Source-built candidates:

```sh
artifacts/mpv-build/mpv --no-config --vo=gpu-next --gpu-api=vulkan --gpu-context=macvk --hwdec=videotoolbox assets/test-clips/hdr10-30.mp4
artifacts/erika-target/debug/macos_native_demo assets/test-clips/hdr10-30.mp4
artifacts/erika-target/debug/metal_import_videotoolbox assets/test-clips/hdr10-30.mp4
```

The mpv build links the locally built, pinned libplacebo 7.371.0. Build scripts supply a missing dav1d include directory for libplacebo's upstream header tests. There are no local changes to those upstream sources. Build outputs use local absolute paths; rebuild them after moving the checkout.

## Models

The download script verifies archive size and SHA-256 before extraction, extracts only named members, and verifies the final model files against the committed manifest. It sorts Safetensors JSON headers before each conversion stage because upstream metadata ordering is nondeterministic; tensor bytes are copied unchanged. New models are prepared in staging before publication. Existing mismatched files produce an error instead of being overwritten. Partial downloads remain under `.part`; rerunning downloads them again.

NR provenance: the public RankFTW `dlssnr-310.8.0` archive contains the NVIDIA-signed DLL with SHA-256 `e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e`. Local Authenticode verification passes. The exact upstream reference (`ceb6432f…`) was also downloaded: its signature fails, but its entire `WEIGHTS_HT` resource is byte-identical to ours. Keep the signed original. The fork recognizes its hash, and source/model checksums remain locked. See [verification evidence and reproduction commands](nr-dll-verification.md). Weight equality is established; NVIDIA runtime-output parity remains unmeasured.

FG comes from the official NVIDIA DLSS SDK Git revision in `config/downloads.json`. VSR comes from NVIDIA's Python package index and its extracted library exactly matches the hash required by the upstream converter.

DLSS SR is optional and deferred by project priority. If revisited with a suitable CUDA capture, the prepared conversion command is:

```sh
uv run --frozen mlxdlss-weights package-sr \
  models/sources/libnvidia-ngx-dlss.so.310.7.0 /path/to/CAPTURE_DIR models/dlss-sr.srmodel
```

No cloud GPU was rented and no NVIDIA account is required for the downloads already used. Core ML tooling is installed, but no fixed-resolution Core ML models are generated: MLX/Metal is the plan's initial engine.

## M3 and M5

`config/m3-dev.json` limits the smoke workload to three 320×192 frames and builds to two jobs. The memory/cache fields are proposed budgets for the future engine, not enforced limits in the upstream app. Use those tiny inputs during development.

The M5 configuration is an unmeasured starting point. To reproduce the software on the new machine, clone and bootstrap. Generated binaries, model archives, and caches are deliberately excluded from Git; bootstrap downloads or rebuilds them. `BUILD_JOBS=6 bash scripts/build-mlx.sh` enables additional compiler workers after confirming available memory.

Before performance comparisons, record source, processing, and output sizes, model hashes, power/display conditions, warm-up, completed GPU timings and peak memory. The smoke script is a correctness check and includes startup overhead. It is not a benchmark or a quality assessment.
