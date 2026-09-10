#!/usr/bin/env python3
"""Alternate development adapter runs at the same source, neural and drawable sizes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--repeat', type=int, default=2)
    parser.add_argument('--width', type=int, default=160)
    parser.add_argument('--height', type=int, default=96)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if not (10 <= args.seconds <= 3600 and 1 <= args.repeat <= 5):
        parser.error('require 10…3600 seconds and 1…5 alternating pairs')
    if not (1 <= args.width <= 16384 and 1 <= args.height <= 16384):
        parser.error('processing dimensions must be within 1…16384')
    root = Path(__file__).resolve().parents[1]
    source, model, output = args.source.resolve(), args.model.resolve(), args.output.resolve()
    metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_format',
        '-show_streams', '-of', 'json', str(source)]))
    if float(metadata['format']['duration']) < args.seconds + 6:
        parser.error('source must be at least 6 seconds longer than the playback interval')
    if not any(stream['codec_type'] == 'audio' for stream in metadata['streams']):
        parser.error('comparison source must contain audio for both device clocks')
    if output.exists() and any(output.iterdir()):
        parser.error('output directory must be new or empty')
    output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        for adapter in ['mpv', 'erika']:
            with (output / f'build-{adapter}.log').open('w') as log:
                subprocess.run(['bash', f'scripts/build-{adapter}-adapter.sh'], cwd=root,
                    stdout=log, stderr=subprocess.STDOUT, check=True)
    binaries = ['artifacts/mpv-build/mpv', 'artifacts/mpv-build/libmpv.2.dylib',
        'artifacts/erika-target/debug/macos_native_demo', '.build/debug/libFrameEngineShared.dylib',
        '.build/debug/mlx.metallib', 'artifacts/erika-target/debug/mlx.metallib']
    revisions = {}
    for name, path in [('root', root), ('mpv', root/'vendor/mpv'), ('Erika', root/'vendor/Erika'),
                       ('MLX-DLSS', root/'vendor/MLX-DLSS')]:
        def git(*values):
            return subprocess.check_output(['git', '-C', str(path), *values])
        revisions[name] = {'revision': git('rev-parse', 'HEAD').decode().strip(),
            'status': git('status', '--porcelain').decode().splitlines(),
            'trackedDiffSHA256': hashlib.sha256(git('diff', 'HEAD', '--binary')).hexdigest()}
    report = {'schemaVersion': 1, 'sourceSHA256': digest(source),
        'modelSHA256': digest(model/'weights.safetensors'), 'revisions': revisions,
        'binarySHA256': {path: digest(root/path) for path in binaries},
        'processingWidth': args.width, 'processingHeight': args.height,
        'drawableWidth': 960, 'drawableHeight': 496, 'runs': [],
        'scope': 'M3 development comparison; same source/model/shape/drawable, foreground requested and app-muted audio; no final M5 selection',
        'limitations': ['mpv Adaptive buffers both clocks; Erika currently drops unsustainable admissions',
            'Navigation harnesses differ: mpv rapid original-first seek/comparison, Erika one scheduled seek',
            'mpv A/V is cached audio-minus-video at queue time; Erika is video-minus-audio estimated at drawable presentation',
            'Physical display luminance, temporal quality, copies and energy remain separate acceptance checks']}
    try:
        for index in range(args.repeat):
            for adapter in ['mpv', 'erika']:
                path = output/f'{adapter}-{index+1}.json'
                environment = dict(os.environ)
                if adapter == 'mpv':
                    values = [sys.executable, 'scripts/test-mpv-policy.py', str(source), '--model', str(model),
                        '--seconds', str(args.seconds), '--width', str(args.width), '--height', str(args.height),
                        '--report', str(path)]
                else:
                    environment.update(ERIKA_FRAME_ENGINE_REPORT=str(path), ERIKA_FRAME_ENGINE_CAPTURE='none',
                        ERIKA_FRAME_ENGINE_WIDTH=str(args.width), ERIKA_FRAME_ENGINE_HEIGHT=str(args.height),
                        ERIKA_FRAME_ENGINE_STRENGTH='1', ERIKA_ADAPTER_FOREGROUND='1', ERIKA_ADAPTER_MUTE='1',
                        ERIKA_ADAPTER_DISPLAY_WIDTH='960', ERIKA_ADAPTER_DISPLAY_HEIGHT='496',
                        ERIKA_ADAPTER_SECONDS=str(args.seconds+4), ERIKA_ADAPTER_SEEK_AT='4', ERIKA_ADAPTER_SEEK_TO='0.73')
                    values = ['bash', 'scripts/run-erika-adapter.sh', str(source), str(model)]
                started = time.time()
                with path.with_suffix('.runner.log').open('w') as log:
                    subprocess.run(values, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
                engine_path = path.with_suffix('.engine.json') if adapter == 'mpv' else path
                engine = json.loads(engine_path.read_text())
                config = engine['configuration']
                if (config['displayWidth'], config['displayHeight'], config['processingWidth'], config['processingHeight']) != (960,496,args.width,args.height):
                    raise RuntimeError(f'{adapter} reported different actual dimensions')
                if engine['warmedSamples'] < 60:
                    raise RuntimeError(f'{adapter} has fewer than 60 warmed completed frames')
                if any(digest(root/name) != value for name,value in report['binarySHA256'].items()):
                    raise RuntimeError('An adapter or shared runtime binary changed during comparison')
                report['runs'].append({'adapter': adapter, 'index': index+1, 'startedUnixSeconds': started,
                    'report': path.name, 'completed': engine['completedTotal'], 'warmed': engine['warmedSamples'],
                    'completedFPS': engine['completedThroughputFPS'], 'power': config['powerConfiguration']})
                (output/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
        report['capturePassed'] = True
        report['presentationComparisonQualified'] = False
        report['limitations'].append('Capture success verifies completed counts and dimensions; it does not qualify actual presentation or select a core')
    except Exception as error:
        report['capturePassed'] = False
        report['error'] = str(error)
        raise
    finally:
        (output/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['runs'],indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'compare-adapters: {error}', file=sys.stderr)
        raise SystemExit(1)
