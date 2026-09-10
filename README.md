# Metal DLSS Mac Video

Development workspace for a native macOS HDR player with experimental MLX/Metal neural enhancement. Development and benchmarks currently run on an M3 with 16 GB. M5 Max with 64 GB is the next target; its performance remains unmeasured.

**Status: implementation in progress.** Native NV12/P010 HDR import, retained-original neural reconstruction, an asynchronous C-compatible frame engine and both native playback adapters are implemented. The AppKit/WKWebView player uses provisional mpv with native video, audio, subtitles and chapters. Shared-clock Adaptive playback and persistent Prepared playback are integrated; the measured M3 Prepared case sustains source cadence.

The [experimental PiP consumer](docs/picture-in-picture.md) is deferred: Apple DTS identifies the tested sample-buffer route as unsupported on macOS. Lifecycle and system-control checks pass, but captured output retains a crop/brightness discrepancy; PiP stays disabled in ordinary playback. Physical HDR, sustained presented A/V and final M5 performance retain their acceptance gates. The [original plan](mac-hdr-player-plan.md) and [implementation status](docs/implementation-status.md) track the remaining work.

## Start here

On the prepared Mac:

```sh
bash scripts/build-harness.sh
open "artifacts/HDR Player.app"
bash scripts/test-frame-api.sh
bash scripts/doctor.sh
uv run --frozen scripts/smoke-models.py
```

HDR Player embeds the patched mpv renderer and provides local playback controls; see [native player and packaging](docs/native-player.md). The separate HDRHarness executable provides video-only SDR/PQ/HLG playback and floating-point captures; see [presentation commands](docs/hdr-presentation.md). [Frame-engine commands](docs/frame-engine.md) exercise the integrated neural HDR path and completed-work instrumentation. MLX-DLSS's separate media exporter remains explicitly SDR.

On another Apple Silicon Mac with macOS 26+, full Xcode, and Homebrew:

```sh
git clone https://github.com/ScriptType/metal-dlss-mac-video.git
cd metal-dlss-mac-video
bash scripts/bootstrap.sh
```

Bootstrap installs missing build dependencies without upgrading existing formulae, resolves pinned sources/packages, downloads checksummed model sources, extracts local models, generates fixtures, and builds the harness and both candidate playback cores. It uses two compiler jobs by default. See [setup](docs/setup.md) for individual steps, model provenance, and migration to M5.

## Layout

| Path | Purpose |
|---|---|
| `apps/macos` | AppKit player, native mpv embedding and WKWebView command/state bridge |
| `apps/harness` | Video-only native RGBA16F/EDR diagnostic harness |
| `apps/controls` | Tailwind CLI sources and npm lockfile; assets bundled locally |
| `packages/FrameEngine` | HDR processing, bounded scheduler, metrics, float cache and preparation coordinator |
| `packages/CFrameEngine` | Shared C frame/session API and ownership contract |
| `tools/HDRProbe` | JSON GPU and decoded-frame reports |
| `tools/FrameBenchmark` | Native decoder/shared-engine completed-work benchmark |
| `tools/CFrameConsumer` | Plain C HDR round trip and resource-lifetime check |
| `tools/HDRPiPProbe` | Public AVKit float transport and paused-renderer diagnostics |
| `vendor/MLX-DLSS` | HDR reader/import/reconstruction fork, branch `hdr-player` |
| `vendor/mpv`, `vendor/libplacebo`, `vendor/Erika` | Pinned Git submodules for adapter work |
| `references` | Pinned Windows reference sources, fetched locally |
| `models` | Local proprietary sources and extracted weights, excluded from Git |
| `assets/test-clips` | Generated SDR/PQ/HLG clips and numeric HDR reference |
| `config` | Download hashes, reference revisions, M3/M5 starting profiles |
| `artifacts` | Local applications, build outputs, reports and captures |

## Model availability

| Model | Preparation result |
|---|---|
| DLSS neural rendering | NVIDIA-signed source verified; embedded weights match upstream's reference byte for byte. Image and temporal-video smoke tests pass on M3. [DLL verification](docs/nr-dll-verification.md). |
| DLSS frame generation | Extracted from NVIDIA SDK 310.7.0; native three-to-five-frame smoke passes. |
| RTX VSR 2× | Extracted from NVIDIA's VFX package, matching upstream's exact source hash; image smoke passes. |
| DLSS SR 2× | Optional and deferred. SDK library downloaded; preparing a `.srmodel` later would require a one-time NVIDIA/CUDA capture. |

Sources and file hashes are in [downloads](config/downloads.json) and the [model manifest](models/manifest.json). These are experimental compatibility models, not official NVIDIA macOS support. See the [upstream preparation instructions](https://github.com/iamwavecut/MLX-DLSS/blob/6499d59c900f5e525d800e951f0000880d85c9f9/docs/super-resolution.md).

## Validation

```sh
bash scripts/check.sh          # engine/cache/harness tests, C ABI, assets and GPU/decode checks
bash scripts/test-cores.sh     # existing mpv/libplacebo/MLX core suites
python3 scripts/fetch-models.py --verify
```

Read the [frame-engine contract](docs/frame-engine.md), [presentation policy](docs/hdr-presentation.md) and [cache encoding policy](docs/hdr-cache.md). The [preparation report](docs/preparation-report.md) records the original baseline. CI builds the harness/engine without downloading NVIDIA binaries or weights. Physical HDR accuracy, sustained playback and target performance retain their explicit hardware validation gates.

Original project code is GPL-3.0-or-later. Third-party code retains its own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Model files are local research assets and are not included in this source repository.
