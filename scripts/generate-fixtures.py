#!/usr/bin/env python3
"""Generate local synthetic clips, with independent FFmpeg transfer conversion."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets/test-clips"
FFMPEG = os.environ.get("FFMPEG_BIN", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
FFPROBE = os.environ.get("FFPROBE_BIN", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")


def run(*args):
    subprocess.run(args, check=True)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    clips = []
    # SDR source is explicitly interpreted as BT.709; zscale converts HDR pixels,
    # so the HDR variants are not merely SDR samples with relabelled metadata.
    for name, fps, transfer, primaries in [
        ("sdr-24", 24, "bt709", "bt709"),
        ("hdr10-30", 30, "smpte2084", "bt2020"),
        ("hlg-60", 60, "arib-std-b67", "bt2020"),
    ]:
        path = OUTPUT / f"{name}.mp4"
        matrix = "bt709" if primaries == "bt709" else "bt2020nc"
        if not path.exists():
            # Synthetic pattern contains motion, saturated colours, and fine detail.
            filters = "format=yuv420p10le,zscale=pin=bt709:tin=bt709:min=bt709:rin=limited"
            filters += f":p={primaries}:t={transfer}:m={matrix}:r=limited:npl=1000,format=yuv420p10le"
            params = "pools=1:frame-threads=1:log-level=error:keyint=120"
            if name.startswith("hdr10"):
                params += ":hdr10=1:repeat-headers=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400"
            staging = path.with_name(path.stem + ".part.mp4")
            run(FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", f"testsrc2=size=320x192:rate={fps}:duration=2",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                "-vf", filters, "-c:v", "libx265", "-preset", "ultrafast", "-crf", "12",
                "-x265-params", params, "-tag:v", "hvc1", "-color_primaries", primaries,
                "-color_trc", transfer, "-colorspace", matrix, "-color_range", "tv",
                "-c:a", "aac", "-b:a", "96k", "-shortest", "-movflags", "+faststart", str(staging))
            staging.replace(path)
        probe = json.loads(subprocess.check_output([
            FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
        video = next(s for s in probe["streams"] if s["codec_type"] == "video")
        assert video["color_transfer"] == transfer, video
        assert video["color_primaries"] == primaries, video
        assert video["pix_fmt"] == "yuv420p10le", video
        clips.append({"file": path.name, "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest(),
                      "video": video, "source": "FFmpeg lavfi testsrc2 and sine; generated locally"})
    image = OUTPUT / "smoke.png"
    if not image.exists():
        y, x = np.mgrid[:192, :320]
        rgb = np.stack([x / 319, y / 191, 0.5 + 0.5 * np.sin(x / 12)], axis=-1)
        Image.fromarray((rgb * 255).astype("uint8")).save(image)
    # Numeric reference for future HDR captures: absolute nits in linear BT.2020.
    # Top half is grey, bottom half includes BT.2020 primaries outside BT.709.
    reference = np.zeros((192, 320, 3), dtype=np.float32)
    reference[:96] = np.linspace(0, 1000, 320, dtype=np.float32)[None, :, None]
    for channel in range(3):
        reference[96:, channel * 106:(channel + 1) * 106, channel] = 203
    reference[96:, 318:] = 10000
    np.save(OUTPUT / "linear-bt2020-nits.npy", reference)
    (OUTPUT / "linear-bt2020-nits.json").write_text(json.dumps({
        "dtype": "float32", "shape": [192, 320, 3], "layout": "HWC RGB", "primaries": "BT.2020",
        "transfer": "linear", "units": "cd/m2", "referenceWhiteNits": 203,
        "description": "0-1000 nit grey ramp, 203 nit saturated primaries, 10000 nit white edge"
    }, indent=2) + "\n")
    (OUTPUT / "manifest.json").write_text(json.dumps(clips, indent=2) + "\n")
    print(f"Verified {len(clips)} clips in {OUTPUT}")


if __name__ == "__main__":
    main()
