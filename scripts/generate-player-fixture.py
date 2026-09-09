#!/usr/bin/env python3
"""Add deterministic audio/subtitle/chapters to the local HDR fixture."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
source = root / "assets/test-clips/hdr10-30.mp4"
output = source.with_name("player-controls.mkv")
if not source.exists():
    raise SystemExit("Run scripts/generate-fixtures.py first")
with tempfile.TemporaryDirectory(prefix="hdr-player-fixture-") as temporary:
    directory = Path(temporary)
    subtitle = directory / "captions.srt"
    subtitle.write_text("1\n00:00:00,000 --> 00:00:01,400\nNative HDR subtitle fixture\n\n2\n00:00:01,500 --> 00:00:03,000\nSecond chapter and audio track\n")
    metadata = directory / "chapters.txt"
    metadata.write_text(";FFMETADATA1\ntitle=HDR Player controls fixture\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1500\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1500\nEND=3000\ntitle=Second chapter\n")
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=3", "-i", str(subtitle),
        "-f", "ffmetadata", "-i", str(metadata), "-map", "0:v:0", "-map", "0:a:0", "-map", "1:a:0", "-map", "2:s:0",
        "-map_metadata", "3", "-map_chapters", "3", "-c:v", "copy", "-c:a", "aac", "-c:s", "srt",
        "-metadata:s:a:0", "title=Original tone", "-metadata:s:a:0", "language=eng",
        "-metadata:s:a:1", "title=Alternate 660 Hz", "-metadata:s:a:1", "language=deu",
        "-metadata:s:s:0", "title=English captions", "-metadata:s:s:0", "language=eng", "-t", "3", str(output)], check=True)
print(output)
