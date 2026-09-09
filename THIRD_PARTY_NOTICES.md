# Third-party components

Original code in this root repository is GPL-3.0-or-later; see `LICENSE`. This choice anticipates the planned GPL mpv integration. It does not relicense any dependency or model.

| Component | Source / licence at pinned revision |
|---|---|
| MLX-DLSS | `vendor/MLX-DLSS/LICENSE`, Apache-2.0; preserve its NOTICE |
| MLX Swift | Upstream Swift package, MIT |
| Swift Numerics / Argument Parser | Resolved by MLX-DLSS, Apache-2.0 |
| mpv | `vendor/mpv/Copyright`, predominantly GPL-2.0-or-later; build configuration affects distributed binaries |
| libplacebo | `vendor/libplacebo/LICENSE`, LGPL-2.1-or-later |
| Erika | `vendor/Erika/LICENSE`, MPL-2.0 |
| FFmpeg / subtitle stack | Erika builds the LGPL profile from pinned source; Homebrew FFmpeg builds include GPL components |
| Tailwind CSS | MIT; npm dependency licences remain in installed packages |
| NVIDIA DLSS / VFX source binaries and extracted models | Vendor terms, not covered by this repository's source licence; all kept outside Git |

The three reference repositories are not linked into the app and no implementation has been copied from them. Their own notices apply to any later reuse.

This repository publishes source and preparation scripts only. It contains no NVIDIA binaries, weights, CUDA captures or third-party media. A future distributable app needs bundled dependency notices, corresponding source where required, and a review of the actual linked components and vendor distribution terms.
