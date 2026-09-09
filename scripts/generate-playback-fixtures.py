#!/usr/bin/env python3
"""Continuous clock fixtures with long GOPs, VFR, pulse audio and styled subtitles."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = os.environ.get("FFMPEG_BIN", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
FFPROBE = os.environ.get("FFPROBE_BIN", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")
PROFILES = {"sdr": ("bt709", "bt709"), "pq": ("bt2020", "smpte2084"),
            "hlg": ("bt2020", "arib-std-b67")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--profile", choices=["all", *PROFILES], default="all")
    parser.add_argument("--rate", type=int, choices=[24, 30, 60])
    parser.add_argument("--output", type=Path, default=ROOT / "assets/test-clips/playback")
    args = parser.parse_args()
    if not 6 <= args.duration <= 3600:
        parser.error("duration must be between 6 and 3600 seconds")
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    profiles = PROFILES if args.profile == "all" else {args.profile: PROFILES[args.profile]}
    with tempfile.TemporaryDirectory(prefix="hdr-playback-fixture-") as directory:
        temporary = Path(directory)
        subtitles = temporary / "captions.ass"
        subtitles.write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 384
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,26,&H00FFFFFF,&H0000FFFF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:03.00,Default,,0,0,0,,{\\c&H00FFFF&}Native ASS{\\c&HFFFFFF&} · subtitle brightness
Dialogue: 0,0:00:03.00,0:00:06.00,Default,,0,0,0,,{\\pos(320,64)\\i1}Positioned italic caption
Dialogue: 0,0:00:06.00,0:00:10.00,Default,,0,0,0,,{\\fad(250,250)}Fade and outline · HDR video below
""")
        metadata = temporary / "chapters.txt"
        chapter_lines = [";FFMETADATA1", "title=Continuous HDR clock and controls fixture"]
        for index, start in enumerate(range(0, args.duration, max(1, args.duration // 3))):
            end = min(args.duration, start + max(1, args.duration // 3))
            chapter_lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start * 1000}",
                              f"END={end * 1000}", f"title=Section {index + 1}"]
        metadata.write_text("\n".join(chapter_lines) + "\n")
        for profile, (primaries, transfer) in profiles.items():
            for rate in ([args.rate] if args.rate else [24, 30, 60]):
                # One extra VFR variant per colour profile retains source PTS
                # while removing patterned frames; audio remains continuous.
                for vfr in ([False, True] if rate == 30 else [False]):
                    name = f"{profile}-{rate}{'-vfr' if vfr else ''}-{args.duration}s.mkv"
                    output = args.output / name
                    matrix = "bt709" if profile == "sdr" else "bt2020nc"
                    filters = "drawbox=x=8:y=8:w=40:h=40:color=white:t=fill:enable='lt(mod(t,1),0.04)',"
                    filters += "format=yuv420p10le,zscale=pin=bt709:tin=bt709:min=bt709:rin=limited"
                    filters += f":p={primaries}:t={transfer}:m={matrix}:r=limited:npl=1000,format=yuv420p10le"
                    if vfr:
                        filters += ",select='not(eq(mod(n,5),2))'"
                    parameters = f"pools=1:frame-threads=1:log-level=error:keyint={rate * 5}:min-keyint={rate * 5}:scenecut=0"
                    if profile == "pq":
                        parameters += ":hdr10=1:repeat-headers=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400"
                    pulse = f"aevalsrc=if(lt(mod(t\\,1)\\,0.04)\\,0.5*sin(2*PI*1000*t)\\,0):s=48000:d={args.duration}"
                    command = [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        "-f", "lavfi", "-i", f"testsrc2=size=320x192:rate={rate}:duration={args.duration}",
                        "-f", "lavfi", "-i", pulse, "-f", "lavfi", "-i",
                        f"sine=frequency=660:sample_rate=48000:duration={args.duration}",
                        "-i", str(subtitles), "-f", "ffmetadata", "-i", str(metadata),
                        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s",
                        "-map_metadata", "4", "-map_chapters", "4", "-vf", filters,
                        "-fps_mode", "vfr" if vfr else "cfr", "-c:v", "libx265", "-preset", "ultrafast",
                        "-crf", "12", "-x265-params", parameters, "-color_primaries", primaries,
                        "-color_trc", transfer, "-colorspace", matrix, "-color_range", "tv",
                        "-c:a", "pcm_s16le", "-c:s", "ass", "-metadata:s:a:0", "title=One-second sync pulses",
                        "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "title=Alternate continuous tone",
                        "-metadata:s:a:1", "language=deu", "-metadata:s:s:0", "title=Styled ASS fixture",
                        "-metadata:s:s:0", "language=eng", "-t", str(args.duration), str(output.with_suffix(".part.mkv"))]
                    if not output.exists():
                        subprocess.run(command, check=True)
                        output.with_suffix(".part.mkv").replace(output)
                    probe = json.loads(subprocess.check_output([FFPROBE, "-v", "error", "-show_streams",
                        "-show_chapters", "-show_format", "-of", "json", str(output)]))
                    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
                    assert video["color_transfer"] == transfer and video["color_primaries"] == primaries
                    assert len([s for s in probe["streams"] if s["codec_type"] == "audio"]) == 2
                    frames = json.loads(subprocess.check_output([FFPROBE, "-v", "error", "-select_streams", "v:0",
                        "-show_frames", "-show_entries", "frame=pts,pts_time,key_frame", "-of", "json", str(output)]))["frames"]
                    times = [int(f["pts"]) for f in frames]
                    assert all(b > a for a, b in zip(times, times[1:])), "non-increasing video timestamps"
                    expected_frames = rate * args.duration * (4 if vfr else 5) // 5
                    assert len(times) == expected_frames, (len(times), expected_frames)
                    keys = [float(f["pts_time"]) for f in frames if f["key_frame"]]
                    with output.open("rb") as file:
                        sha256 = hashlib.file_digest(file, "sha256").hexdigest()
                    result = {"file": name, "sha256": sha256, "nominalRate": rate, "vfr": vfr,
                        "frameCount": len(frames), "videoTimebase": video["time_base"], "videoPTS": times,
                        "keyframeSeconds": keys, "durationSeconds": args.duration, "profile": profile,
                        "audio": "48 kHz PCM; 40 ms 1 kHz pulse at each integer second; alternate continuous 660 Hz",
                        "visualPulse": "40x40 white square at (8,8) for first40 ms of each second before HDR conversion",
                        "source": "Continuous FFmpeg lavfi testsrc2; long GOP; generated synthetic material",
                        "probe": probe}
                    output.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
                    results.append({key: value for key, value in result.items() if key not in ["probe", "videoPTS"]})
                    print(f"Verified {name}: {len(frames)} frames, {len(keys)} keyframes", flush=True)
    (args.output / "manifest.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
