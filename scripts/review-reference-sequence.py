#!/usr/bin/env python3
"""Create bounded CPU-only SDR review images from a completed four-view capture.

Raw RGB32F references remain authoritative. PNGs and the local HTML viewer are
explicitly mapped/quantized inspection aids, not HDR or presentation evidence.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile

import numpy as np
from PIL import Image, ImageCms

VIEWS = ("original", "proxy", "identity", "enhanced")
LAYOUT = "RGB float32 little-endian top-to-bottom"
BT2020_TO_709 = np.array([[1.6604910, -0.5876411, -0.0728499],
                          [-0.1245505, 1.1328999, -0.0083494],
                          [-0.0181508, -0.1005789, 1.1187297]], dtype=np.float64)
LUMA_709 = np.array([0.2126, 0.7152, 0.0722])
MAX_BYTES = 2 * 1024**3
MAX_MANIFEST = 1024**2


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def read_json(path: Path) -> dict:
    assert 0 < path.stat().st_size <= MAX_MANIFEST, "Manifest exceeds 1 MiB"
    value = json.loads(path.read_text())
    assert isinstance(value, dict), "Expected a JSON object"
    return value


def contained(directory: Path, name: str) -> Path:
    assert isinstance(name, str) and name and not Path(name).is_absolute(), "Expected a relative path"
    path = (directory / name).resolve(strict=True)
    assert path.is_relative_to(directory.resolve()) and path.is_file(), "Path escapes capture directory"
    return path


def rational(value: dict) -> Fraction:
    assert isinstance(value, dict) and type(value.get("value")) is int, "Invalid rational value"
    scale = value.get("timescale")
    assert type(scale) is int and 0 < scale <= 2**31 - 1, "Invalid rational timescale"
    assert -(2**63) <= value["value"] < 2**63, "Rational value exceeds Int64"
    return Fraction(value["value"], scale)


def load_view(directory: Path, metadata: dict, width: int, height: int) -> np.ndarray:
    path = contained(directory, metadata["path"])
    expected = width * height * 12
    assert metadata["bytes"] == expected and path.stat().st_size == expected, "RGB32F size mismatch"
    assert digest(path) == metadata["sha256"], f"RGB32F hash mismatch: {path.name}"
    pixels = np.fromfile(path, dtype="<f4").reshape(height, width, 3)
    assert np.isfinite(pixels).all(), "Nonfinite reference components"
    return pixels


def mapped_srgb(rgb: np.ndarray, white: float) -> tuple[np.ndarray, dict]:
    """CPU reference for the current codec's fixed SDR proxy display mapping.

    No per-frame exposure or histogram adaptation. Negative source components
    are counted before the codec-equivalent max(0) operation; originals on disk
    are never modified. Values after matrix/rolloff are counted before gamut
    clipping and standard sRGB encoding.
    """
    linear = np.maximum(rgb.astype(np.float64), 0) / white
    display = linear @ BT2020_TO_709.T
    luminance = display @ LUMA_709
    mask = luminance > 0.75
    rolled = 0.75 + 0.25 * (-np.expm1(-(luminance[mask] - 0.75) / 0.25))
    display[mask] *= (rolled / luminance[mask])[:, None]
    statistics = {"negativeSourceComponentsClippedForReview": int((rgb < 0).sum()),
                  "mappedComponentsBelowZero": int((display < 0).sum()),
                  "mappedComponentsAboveOne": int((display > 1).sum()),
                  "pixelsInHighlightRolloff": int(mask.sum())}
    clipped = np.clip(display, 0, 1)
    encoded = np.where(clipped < 0.0031308, clipped * 12.92,
                       1.055 * np.power(clipped, 1 / 2.4) - 0.055)
    return encoded, statistics


def preview(rgb: np.ndarray, name: str, white: float) -> tuple[np.ndarray, dict]:
    if name == "proxy":
        assert ((rgb >= 0) & (rgb <= 1)).all(), "Proxy is not bounded encoded sRGB"
        encoded = rgb.astype(np.float64)
        stats = {"mapping": "Already encoded sRGB proxy; no HDR mapping or second transfer function"}
    else:
        encoded, stats = mapped_srgb(rgb, white)
        stats["mapping"] = "fixed BT2020-nits to bounded sRGB"
    quantized = np.floor(np.clip(encoded, 0, 1) * 255 + 0.5).astype(np.uint8)
    error = quantized.astype(np.float64) / 255 - encoded
    stats.update(encodedQuantizationMaximumError=float(np.abs(error).max()),
                 encodedQuantizationRMSError=float(np.sqrt(np.mean(error**2))))
    return quantized, stats


def error_statistics(delta: np.ndarray) -> dict:
    return {"maximumAbsoluteNits": float(np.abs(delta).max()),
            "meanAbsoluteNits": float(np.abs(delta).mean()),
            "rmsNits": float(np.sqrt(np.mean(delta**2)))}


def validate_capture(path: Path) -> tuple[dict, list[dict], float]:
    manifest = read_json(path)
    assert manifest.get("schemaVersion") == 1 and manifest.get("complete") is True, "Capture is incomplete or unsupported"
    assert manifest["layout"] == LAYOUT and tuple(manifest["views"]) == VIEWS, "Unsupported capture layout/views"
    assert manifest["referenceDomain"] == {"primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"}
    assert manifest["proxyDomain"] == {"primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"}
    width, height = manifest["width"], manifest["height"]
    assert type(width) is int and type(height) is int and width > 0 and height > 0 and width * height <= 2_073_600
    frames = manifest["frames"]
    assert 1 <= len(frames) <= 120 and len(frames) == manifest["completedFrames"] == manifest["requestedFrames"]
    assert width * height * 48 * len(frames) <= MAX_BYTES, "Reference payload exceeds 2 GiB"
    source_manifest = contained(path.parent, manifest["inputManifestCopy"])
    assert digest(source_manifest) == manifest["inputManifestSHA256"], "Source manifest copy changed"
    source = read_json(source_manifest)
    assert source["schemaVersion"] == 1 and source["width"] == width and source["height"] == height
    assert source["layout"] == LAYOUT and source["primaries"] == "BT.2020" and source["transfer"] == "linear" and source["units"] == "cd/m2"
    assert source["provenance"] == manifest["provenance"], "Source colour/provenance changed"
    white = float(manifest["settings"]["referenceWhiteNits"])
    assert np.isfinite(white) and white > 0
    previous_pts, previous_index = None, None
    for ordinal, frame in enumerate(frames):
        assert frame["ordinal"] == ordinal and set(frame["views"]) == set(VIEWS)
        pts, duration = rational(frame["pts"]), rational(frame["duration"])
        assert duration > 0 and (previous_pts is None or pts > previous_pts), "Unordered PTS"
        index = frame["sourceFrameIndex"]
        assert type(index) is int and 0 <= index < 2**63 - 1 and (previous_index is None or index > previous_index)
        original = source["frames"][ordinal]
        assert original["sourceFrameIndex"] == index and rational(original["pts"]) == pts and rational(original["duration"]) == duration
        assert original["sha256"].lower() == frame["inputSHA256"] and original["path"] == frame["inputPath"]
        assert frame["views"]["original"]["sha256"] == frame["inputSHA256"], "Retained original differs from input"
        assert frame["generation"] == manifest["generation"]
        previous_pts, previous_index = pts, index
        for metadata in frame["views"].values():
            # Streaming preflight: no previews are published for an invalid run.
            load_view(path.parent, metadata, width, height)
    return manifest, frames, white


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def review(path: Path, output: Path) -> dict:
    manifest, frames, white = validate_capture(path)
    assert not output.exists(), "Review directory already exists"
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    records = []
    previous_residual = None
    previous_pts = None
    width, height = manifest["width"], manifest["height"]
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    try:
        for ordinal, frame in enumerate(frames):
            views = {name: load_view(path.parent, frame["views"][name], width, height) for name in VIEWS}
            images, mappings = [], {}
            for name in VIEWS:
                pixels, statistics = preview(views[name], name, white)
                images.append(pixels)
                mappings[name] = statistics
            # Panel labels live in HTML and manifest, never cover source pixels.
            contact = np.concatenate(images, axis=1)
            image_path = staging / f"frame-{ordinal:04d}.png"
            Image.fromarray(contact).save(image_path, icc_profile=icc, compress_level=4)
            identity_error = views["identity"].astype(np.float64) - views["original"]
            residual = views["enhanced"].astype(np.float64) - views["original"]
            pts = rational(frame["pts"])
            record = {"ordinal": ordinal, "sourceFrameIndex": frame["sourceFrameIndex"],
                      "pts": frame["pts"], "duration": frame["duration"],
                      "sourceFrameIndexLabel": str(frame["sourceFrameIndex"]),
                      "ptsLabel": f'{frame["pts"]["value"]}/{frame["pts"]["timescale"]}',
                      "durationLabel": f'{frame["duration"]["value"]}/{frame["duration"]["timescale"]}',
                      "playbackSeconds": float(pts - rational(frames[0]["pts"])),
                      "durationSeconds": float(rational(frame["duration"])),
                      "generation": frame["generation"], "historyReset": frame["historyReset"],
                      "knownInputDiscontinuities": frame["knownInputDiscontinuities"],
                      "specificResetOrCutCause": frame["specificResetOrCutCause"],
                      "usedModel": frame["usedModel"], "image": image_path.name,
                      "imageSHA256": digest(image_path), "mappingStatistics": mappings,
                      "identityMinusOriginal": error_statistics(identity_error),
                      "enhancedMinusOriginal": error_statistics(residual),
                      "temporalResidualDelta": error_statistics(residual - previous_residual) if previous_residual is not None else None,
                      "previousPTSDeltaSeconds": float(pts - previous_pts) if previous_pts is not None else None}
            records.append(record)
            previous_residual, previous_pts = residual, pts
        report = {"schemaVersion": 1, "complete": True, "captureManifest": str(path),
                  "captureManifestSHA256": digest(path), "inputManifestSHA256": manifest["inputManifestSHA256"],
                  "provenance": manifest["provenance"], "widthPerPanel": width, "height": height,
                  "panelOrder": list(VIEWS), "frames": records,
                  "mapping": {"name": "fixed SDR inspection, codec-equivalent v1",
                              "referenceWhiteNits": white, "negativeSourceClamp": "max(component,0) for review only",
                              "BT2020toBT709": BT2020_TO_709.tolist(), "luminance709": LUMA_709.tolist(),
                              "rolloff": "Y>0.75: Y'=0.75+0.25*(1-exp(-(Y-0.75)/0.25)); scale RGB by Y'/Y",
                              "gamut": "clip mapped BT709 components to0...1 before sRGB encoding",
                              "encoding": "sRGB piecewise OETF, threshold0.0031308; round to nearest8-bit code; embedded sRGB ICC",
                              "proxy": "already bounded encoded sRGB; only8-bit quantization"},
                  "tools": {"scriptSHA256": digest(Path(__file__)), "python": platform.python_version(),
                            "numpy": np.__version__, "pillow": Image.__version__},
                  "limitations": ["Working RGB32F references remain unchanged; mapped PNGs are SDR inspection aids",
                                  "Temporal residual delta compares stationary coordinates; scene motion/cuts can dominate it and it is not a quality score",
                                  "Combined historyReset does not identify a specific scene cut or flow-backend cause",
                                  "HTML scheduling is a review convenience, not physical playback or A/V evidence"]}
        write_json(staging / "review.json", report)
        data = json.dumps(report, ensure_ascii=True, allow_nan=False).replace("<", "\\u003c")
        (staging / "index.html").write_text(HTML.replace("__DATA__", data))
        total = sum(item.stat().st_size for item in staging.iterdir())
        assert total <= MAX_BYTES, "Review artifact exceeds 2 GiB"
        # Revalidate the run marker after readback; source captures are immutable.
        assert digest(path) == report["captureManifestSHA256"], "Capture manifest changed during review"
        staging.rename(output)
        return report
    except BaseException:
        shutil.rmtree(staging)
        raise


HTML = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Temporal reference review</title><style>
body{font:16px system-ui;background:#151515;color:#eee;margin:20px}button,input{font:inherit;margin:8px}figure{margin:0;overflow:auto}
.labels{display:grid;grid-template-columns:repeat(4,1fr);min-width:800px;text-align:center}img{display:block;width:100%;min-width:800px}
pre{white-space:pre-wrap}label{display:inline-block}#position{width:50vw}</style>
<h1>Temporal reference review</h1><p>Fixed SDR mapping. Raw float references are authoritative. Source timing is exact; browser presentation timing is not qualified.</p>
<button id="previous">Previous</button><button id="play">Play</button><button id="next">Next</button>
<label>Speed <select id="speed"><option value="0.25">¼×</option><option value="0.5">½×</option><option value="1" selected>1×</option></select></label>
<input id="position" type="range" min="0" value="0" aria-label="Frame"><p id="timing"></p>
<figure><div class="labels"><span>Original · mapped SDR</span><span>Neural proxy · sRGB</span><span>Identity · mapped SDR</span><span>Enhanced · mapped SDR</span></div><img id="image" alt="Same-frame original, proxy, identity and enhanced views"></figure>
<pre id="details"></pre><script>const report=__DATA__, frames=report.frames;
let current=0,playing=false,start=0,offset=0,skipped=0,token=0,imageRevision=0;
const el=id=>document.getElementById(id);el('position').max=frames.length-1;
function show(i){current=i;const f=frames[i],revision=++imageRevision;el('position').value=i;
el('timing').textContent=`Loading source ${f.sourceFrameIndexLabel} at PTS ${f.ptsLabel}`;
const pending=new Image();pending.onload=()=>{if(revision!==imageRevision)return;el('image').src=pending.src;
el('timing').textContent=`Frame ${i+1}/${frames.length}; source ${f.sourceFrameIndexLabel}; PTS ${f.ptsLabel}; duration ${f.durationLabel}; reset ${f.historyReset}; browser-skipped ${skipped}`;
el('details').textContent=JSON.stringify({knownInputDiscontinuities:f.knownInputDiscontinuities,specificResetOrCutCause:f.specificResetOrCutCause,identityMinusOriginal:f.identityMinusOriginal,enhancedMinusOriginal:f.enhancedMinusOriginal,temporalResidualDelta:f.temporalResidualDelta},null,2);};
pending.onerror=()=>{if(revision===imageRevision){stop();el('timing').textContent='Image failed to load; no frame/timestamp claim'}};pending.src=f.image;}
function stop(){playing=false;++token;el('play').textContent='Play'}
function tick(t,active){if(!playing||active!==token)return;const seconds=offset+(t-start)/1000*Number(el('speed').value);
let i=current;while(i+1<frames.length&&frames[i+1].playbackSeconds<=seconds)i++;if(i!==current){skipped+=Math.max(0,i-current-1);show(i)}
const last=frames[frames.length-1];if(seconds>=last.playbackSeconds+last.durationSeconds){stop();return}requestAnimationFrame(t=>tick(t,active));}
el('play').onclick=()=>{if(playing){stop();return}if(current===frames.length-1)show(0);playing=true;el('play').textContent='Pause';offset=frames[current].playbackSeconds;start=performance.now();const active=++token;requestAnimationFrame(t=>tick(t,active))};
el('previous').onclick=()=>{stop();show(Math.max(0,current-1))};el('next').onclick=()=>{stop();show(Math.min(frames.length-1,current+1))};
el('position').oninput=e=>{stop();show(Number(e.target.value))};el('speed').onchange=stop;show(0);</script></html>"""


def self_test() -> None:
    # Synthetic CPU tests check the mapper and strict integrity path. They do
    # not substitute for a natural-scene neural capture.
    checks = 0
    black, _ = mapped_srgb(np.zeros((1, 1, 3)), 203)
    assert np.array_equal(black, np.zeros((1, 1, 3))); checks += 1
    ramp = np.repeat(np.linspace(0, 2000, 100)[:, None], 3, axis=1).reshape(1, 100, 3)
    mapped, _ = mapped_srgb(ramp, 203)
    assert ((0 <= mapped) & (mapped <= 1)).all() and (np.diff(mapped, axis=1) >= -1e-12).all(); checks += 1
    source = np.array([[[-2.0, 10001.0, 203.0]]], dtype=np.float32)
    saved = source.copy(); _, stats = mapped_srgb(source, 203)
    assert np.array_equal(source, saved) and stats["negativeSourceComponentsClippedForReview"] == 1; checks += 1
    proxy = np.array([[[0, 0.5, 1]]], dtype=np.float32)
    image, _ = preview(proxy, "proxy", 203)
    assert image.tolist() == [[[0, 128, 255]]]; checks += 1
    assert rational({"value": 125, "timescale": 2997}) == rational({"value": 250, "timescale": 5994}); checks += 1
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        pixels = root / "image.rgb32f"; proxy.astype("<f4").tofile(pixels)
        metadata = {"path": pixels.name, "sha256": digest(pixels), "bytes": 12}
        assert np.array_equal(load_view(root, metadata, 1, 1), proxy); checks += 1
        def reject(operation):
            nonlocal checks
            try:
                operation()
            except (AssertionError, FileNotFoundError, ValueError):
                checks += 1
                return
            raise AssertionError("Invalid input accepted")
        reject(lambda: load_view(root, metadata | {"sha256": "0" * 64}, 1, 1))
        reject(lambda: load_view(root, metadata, 2, 1))
        reject(lambda: contained(root, str(pixels)))
        reject(lambda: contained(root, "../missing"))
        reject(lambda: rational({"value": 1, "timescale": 0}))
        bad = np.array([[[0, np.inf, 1]]], dtype="<f4"); bad.tofile(pixels)
        reject(lambda: load_view(root, metadata | {"sha256": digest(pixels)}, 1, 1))
        reject(lambda: preview(np.array([[[0, 2, 1]]]), "proxy", 203))
        # Full two-frame CPU fixture exercises publication, ICC tagging,
        # identity error and stale/incomplete capture rejection.
        capture = root / "capture"; capture.mkdir()
        provenance = {"scope": "synthetic CPU test; no neural result"}
        originals = [np.array([[[-0.1, 20, 10001]]], dtype="<f4"),
                     np.array([[[0, 21, 10002]]], dtype="<f4")]
        input_frames, output_frames = [], []
        for ordinal, original in enumerate(originals):
            directory = capture / f"frame-{ordinal:04d}"; directory.mkdir()
            views = {}
            for name, values in zip(VIEWS, [original, proxy, original, original]):
                target = directory / f"{name}.rgb32f"; values.tofile(target)
                views[name] = {"path": str(target.relative_to(capture)), "sha256": digest(target), "bytes": 12}
            timing = {"value": ordinal * 125, "timescale": 2997}
            duration = {"value": 125, "timescale": 2997}
            source = {"sourceFrameIndex": ordinal + 10000, "path": f"input-{ordinal}.rgb32f",
                      "sha256": views["original"]["sha256"], "pts": timing, "duration": duration}
            input_frames.append(source)
            output_frames.append({"ordinal": ordinal, "sourceFrameIndex": source["sourceFrameIndex"],
                                  "inputSHA256": source["sha256"], "inputPath": source["path"],
                                  "pts": timing, "duration": duration, "generation": 1,
                                  "historyReset": ordinal == 0, "knownInputDiscontinuities": ["cold-start"] if ordinal == 0 else [],
                                  "specificResetOrCutCause": "unavailable", "usedModel": False, "views": views})
        source_manifest = capture / "input-manifest.json"
        write_json(source_manifest, {"schemaVersion": 1, "width": 1, "height": 1,
                                    "layout": LAYOUT, "primaries": "BT.2020", "transfer": "linear", "units": "cd/m2",
                                    "provenance": provenance, "frames": input_frames})
        capture_manifest = capture / "manifest.json"
        captured = {"schemaVersion": 1, "complete": True, "width": 1, "height": 1,
                    "layout": LAYOUT, "views": list(VIEWS), "generation": 1,
                    "referenceDomain": {"primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"},
                    "proxyDomain": {"primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"},
                    "completedFrames": 2, "requestedFrames": 2, "inputManifestCopy": source_manifest.name,
                    "inputManifestSHA256": digest(source_manifest), "provenance": provenance,
                    "settings": {"referenceWhiteNits": 203}, "frames": output_frames}
        write_json(capture_manifest, captured)
        result = review(capture_manifest, root / "review")
        assert len(result["frames"]) == 2 and result["frames"][1]["identityMinusOriginal"]["maximumAbsoluteNits"] == 0
        assert result["frames"][1]["temporalResidualDelta"]["maximumAbsoluteNits"] == 0
        with Image.open(root / "review/frame-0000.png") as image:
            assert image.size == (4, 1) and image.info.get("icc_profile")
        assert digest(capture_manifest) == result["captureManifestSHA256"]
        checks += 1
        write_json(capture_manifest, captured | {"complete": False})
        reject(lambda: validate_capture(capture_manifest))
    print(json.dumps({"passed": True, "checks": checks, "scope": "CPU integrity/mapping; no GPU or natural-scene qualification"}))


def main() -> int:
    if not __debug__:
        print("reference review: Python optimization disables integrity assertions; run without -O/PYTHONOPTIMIZE", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, nargs="?")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test(); return 0
        if args.manifest is None or args.output is None:
            parser.error("manifest and --output are required")
        result = review(args.manifest.resolve(strict=True), args.output.resolve())
        print(json.dumps({"complete": True, "frames": len(result["frames"]), "review": str(args.output / "index.html")}))
        return 0
    except (AssertionError, ValueError, OSError, KeyError, TypeError) as error:
        print(f"reference review: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
