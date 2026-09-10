#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
media="${1:?Usage: run-erika-adapter.sh MEDIA [MODEL_DIRECTORY]}"
export ERIKA_FRAME_ENGINE="$PROJECT_ROOT/.build/debug/libFrameEngineShared.dylib"
export ERIKA_ADAPTER_FOREGROUND="${ERIKA_ADAPTER_FOREGROUND:-1}"
export ERIKA_ADAPTER_DIAGNOSTICS="${ERIKA_ADAPTER_DIAGNOSTICS:-1}"
export ERIKA_FRAME_ENGINE_MODEL="${2:-${ERIKA_FRAME_ENGINE_MODEL:-}}"
if [[ -z "$ERIKA_FRAME_ENGINE_MODEL" ]]; then unset ERIKA_FRAME_ENGINE_MODEL; fi
export ERIKA_FRAME_ENGINE_WIDTH="${ERIKA_FRAME_ENGINE_WIDTH:-32}"
export ERIKA_FRAME_ENGINE_HEIGHT="${ERIKA_FRAME_ENGINE_HEIGHT:-24}"
export ERIKA_FRAME_ENGINE_STRENGTH="${ERIKA_FRAME_ENGINE_STRENGTH:-1}"
export ERIKA_FRAME_ENGINE_REPORT="${ERIKA_FRAME_ENGINE_REPORT:-$PROJECT_ROOT/artifacts/erika-adapter/report.json}"
export ERIKA_FRAME_ENGINE_CAPTURE="${ERIKA_FRAME_ENGINE_CAPTURE:-$PROJECT_ROOT/artifacts/erika-adapter/captures}"
if [[ "$ERIKA_FRAME_ENGINE_CAPTURE" == "none" ]]; then unset ERIKA_FRAME_ENGINE_CAPTURE; fi
mkdir -p "$(dirname "$ERIKA_FRAME_ENGINE_REPORT")"
if [[ -n "${ERIKA_FRAME_ENGINE_CAPTURE:-}" ]]; then mkdir -p "$ERIKA_FRAME_ENGINE_CAPTURE"; fi
export ERIKA_FRAME_ENGINE_MEASUREMENTS
ERIKA_FRAME_ENGINE_MEASUREMENTS="$(python3 - "$media" <<'PY'
import hashlib,json,os,subprocess,sys
from pathlib import Path
path=os.path.realpath(sys.argv[1])
p=json.loads(subprocess.check_output(['/opt/homebrew/opt/ffmpeg-full/bin/ffprobe','-v','error','-select_streams','v:0','-show_streams','-of','json',path]))['streams'][0]
a,b=map(int,p['avg_frame_rate'].split('/'))
model=os.environ.get('ERIKA_FRAME_ENGINE_MODEL')
def digest(path):
 with open(path,'rb') as source: return hashlib.file_digest(source,'sha256').hexdigest()
model_version=digest(os.path.join(model,'weights.safetensors')) if model else 'original'
revision=subprocess.check_output(['git','-C','vendor/Erika','rev-parse','HEAD'],text=True).strip()
if subprocess.check_output(['git','-C','vendor/Erika','status','--porcelain'],text=True).strip(): revision+=' + worktree'
config=dict(adapter='erika-shared-hdr',source=Path(path).name+';sha256='+digest(path),sourceWidth=p['width'],sourceHeight=p['height'],
 processingWidth=int(os.environ['ERIKA_FRAME_ENGINE_WIDTH']),processingHeight=int(os.environ['ERIKA_FRAME_ENGINE_HEIGHT']),
 displayWidth=int(os.environ.get('ERIKA_ADAPTER_DISPLAY_WIDTH','1920')),displayHeight=int(os.environ.get('ERIKA_ADAPTER_DISPLAY_HEIGHT','992')),sourceFPS=a/b,modelVersion=model_version,
 implementationRevision=revision,
 settingsJSON=json.dumps(dict(effectStrength=float(os.environ['ERIKA_FRAME_ENGINE_STRENGTH']),colourStrength=1,referenceWhiteNits=203,maximumLuminanceRatio=2)),
 warmupFrames=3,displayConfiguration='native RGBA16F extended-linear Display P3; current EDR queried each tick',
 powerConfiguration=subprocess.check_output(['pmset','-g','batt'],text=True).strip()+'; app-muted='+os.environ.get('ERIKA_ADAPTER_MUTE','0')+'; no energy measurement')
Path(os.environ['ERIKA_FRAME_ENGINE_REPORT']).with_suffix('.configuration.json').write_text(json.dumps(config,indent=2)+'\n')
print(json.dumps(config))
PY
)"
artifacts/erika-target/debug/macos_native_demo --edr 4 \
  --smoke-seconds "${ERIKA_ADAPTER_SECONDS:-6}" "$media" 2>&1 | tee "${ERIKA_FRAME_ENGINE_REPORT%.json}.native.log"
if [[ "${ERIKA_ADAPTER_REQUIRE_VISIBLE:-0}" == "1" ]]; then
  python3 scripts/adapter_visibility.py --engine "$ERIKA_FRAME_ENGINE_REPORT" \
    --log "${ERIKA_FRAME_ENGINE_REPORT%.json}.native.log" \
    --report "${ERIKA_FRAME_ENGINE_REPORT%.json}.visibility.json"
fi
