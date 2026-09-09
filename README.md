# Metal DLSS Mac Video

Development workspace for a native macOS HDR player with experimental MLX/Metal neural enhancement. Target hardware: M5 Max with 64 GB. The current M3 with 16 GB is used for correctness checks and small inference runs.

**Status: development preparation, not a finished HDR enhancement player.** The native bypass harness plays local video; MLX-DLSS runs separately. The shared asynchronous engine, HDR reconstruction, and player adapters remain to be implemented according to the [original plan](mac-hdr-player-plan.md).

## Start here

On the prepared Mac:

```sh
open "artifacts/HDR Player.app"
open "vendor/MLX-DLSS/.build/MLX DLSS.app"
bash scripts/doctor.sh
uv run --frozen scripts/smoke-models.py
```

In MLX-DLSS, select `models/neural-rendering/NeuralRendering.dlssmodel` for neural rendering, `models/framegen.safetensors` for frame generation, and `models/vsr.safetensors` for RTX VSR. Its current video exports are SDR.

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
| `apps/macos` | AppKit/AVPlayerView native bypass harness, WKWebView controls |
| `apps/controls` | Tailwind CLI sources and npm lockfile; assets bundled locally |
| `packages/FrameEngine` | Initial Metal storage and CoreVideo decode diagnostics |
| `tools/HDRProbe` | JSON GPU and decoded-frame reports |
| `vendor/MLX-DLSS` | Fork at the plan revision, branch `hdr-player` |
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
bash scripts/check.sh          # harness, tool tests, assets and local GPU/decode checks
bash scripts/test-cores.sh     # existing mpv/libplacebo/MLX core suites
python3 scripts/fetch-models.py --verify
```

Read [the preparation report](docs/preparation-report.md) for measured results and their limits. CI builds the standalone harness and checks project sources without downloading NVIDIA binaries or weights. Visual HDR accuracy and sustained performance require local hardware validation.

Original project code is GPL-3.0-or-later. Third-party code retains its own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Model files are local research assets and are not included in this source repository.
