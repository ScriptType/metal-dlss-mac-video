# Local models

Only this README and `manifest.json` are tracked. Download and extract with `python3 scripts/fetch-models.py`; verify without network access with `--verify`.

The manifest records exact generated files, verified NR weight provenance, and deferred optional DLSS SR preparation. Full source archive hashes are in `config/downloads.json`; the NR signature and weight comparison is documented in [the verification report](../docs/nr-dll-verification.md). Never commit vendor libraries, extracted weights, generated model packages, or CUDA captures.
