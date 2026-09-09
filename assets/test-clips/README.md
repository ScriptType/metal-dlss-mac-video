# Local test material

Run `uv run --frozen scripts/generate-fixtures.py`. This creates two-second 320×192 HEVC 10-bit clips: SDR/BT.709 at 24 fps, HDR10/PQ/BT.2020 at 30 fps, and HLG/BT.2020 at 60 fps, each with a synthetic audio tone. FFmpeg zscale converts the pixels before tagging them. The HDR10 stream includes mastering-display and content-light metadata. A generated manifest records hashes and ffprobe output.

`smoke.png` is a small synthetic gradient. `linear-bt2020-nits.npy` contains float32 RGB values in absolute nits, including a grey ramp, saturated BT.2020 primaries, and a 10000-nit edge. Its JSON sidecar defines layout and units. It is a numeric fixture, not a display-ready image.

These files are generated locally and excluded from Git. They are initial diagnostics; passing them does not demonstrate full HDR accuracy or temporal quality on real video.
