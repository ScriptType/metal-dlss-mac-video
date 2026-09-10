#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
probe_bundle="$PROJECT_ROOT/artifacts/pip-probe/HDRPiPProbe.app"
mkdir -p "$probe_bundle/Contents/MacOS" "$probe_bundle/Contents/Resources"
swiftc -swift-version 5 -O -import-objc-header packages/CFrameEngine/include/frame_engine.h \
  tools/HDRPiPProbe/FrameReference.swift tools/HDRPiPProbe/main.swift \
  -o "$probe_bundle/Contents/MacOS/HDRPiPProbe" \
  -L "$PROJECT_ROOT/.build/debug" -lFrameEngineShared \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/.build/debug" \
  -framework AppKit -framework AVKit -framework AVFoundation -framework CoreVideo -framework QuartzCore
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.scripttype.HDRPiPProbe</string>
<key>CFBundleExecutable</key><string>HDRPiPProbe</string>
<key>CFBundleName</key><string>HDR PiP Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$PROJECT_ROOT/.build/debug/mlx.metallib" "$probe_bundle/Contents/Resources/mlx.metallib"
ln -sfn ../Resources/mlx.metallib "$probe_bundle/Contents/MacOS/mlx.metallib"
python3 - "$PROJECT_ROOT" "$probe_bundle" <<'PYTHON'
import datetime, hashlib, json, pathlib, subprocess, sys
root, bundle = map(pathlib.Path, sys.argv[1:])
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
def revision(path):
    return subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
files = [root/'tools/HDRPiPProbe/FrameReference.swift', root/'tools/HDRPiPProbe/main.swift',
         root/'scripts/build-pip-probe.sh', root/'packages/CFrameEngine/include/frame_engine.h',
         root/'.build/debug/libFrameEngineShared.dylib', root/'.build/debug/mlx.metallib',
         bundle/'Contents/MacOS/HDRPiPProbe']
report = {'builtAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'rootRevision': revision(root), 'mpvRevision': revision(root/'vendor/mpv'),
          'mlxDLSSRevision': revision(root/'vendor/MLX-DLSS'),
          'files': [{'path': str(path.relative_to(root)), 'sha256': digest(path),
                     'bytes': path.stat().st_size} for path in files]}
(bundle/'Contents/Resources/build-provenance.json').write_text(json.dumps(report, indent=2)+'\n')
PYTHON
printf '%s\n' "$probe_bundle/Contents/MacOS/HDRPiPProbe"
