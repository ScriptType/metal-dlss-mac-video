#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
media="${1:?Usage: run-erika-adapter.sh MEDIA [MODEL_DIRECTORY]}"
export ERIKA_FRAME_ENGINE="$PROJECT_ROOT/.build/debug/libFrameEngineShared.dylib"
export ERIKA_ADAPTER_FOREGROUND="${ERIKA_ADAPTER_FOREGROUND:-1}"
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
import json,os,subprocess,sys
path=os.path.realpath(sys.argv[1])
p=json.loads(subprocess.check_output(['/opt/homebrew/opt/ffmpeg-full/bin/ffprobe','-v','error','-select_streams','v:0','-show_streams','-of','json',path]))['streams'][0]
a,b=map(int,p['avg_frame_rate'].split('/'))
model=os.environ.get('ERIKA_FRAME_ENGINE_MODEL')
model_version=json.load(open(os.path.join(model,'manifest.json')))['weights']['sha256'] if model else 'bypass'
revision=subprocess.check_output(['git','-C','vendor/Erika','rev-parse','HEAD'],text=True).strip()
if subprocess.check_output(['git','-C','vendor/Erika','status','--porcelain'],text=True).strip(): revision+=' + worktree'
print(json.dumps(dict(adapter='erika-shared-hdr',source=path,sourceWidth=p['width'],sourceHeight=p['height'],
 processingWidth=int(os.environ['ERIKA_FRAME_ENGINE_WIDTH']),processingHeight=int(os.environ['ERIKA_FRAME_ENGINE_HEIGHT']),
 displayWidth=1920,displayHeight=992,sourceFPS=a/b,modelVersion=model_version,
 implementationRevision=revision,
 settingsJSON=json.dumps(dict(effectStrength=float(os.environ['ERIKA_FRAME_ENGINE_STRENGTH']),colourStrength=1,referenceWhiteNits=203,maximumLuminanceRatio=2)),
 warmupFrames=3,displayConfiguration='native RGBA16F extended-linear Display P3; current EDR queried each tick',
 powerConfiguration='uncontrolled development run; no energy measurement')))
PY
)"
exec artifacts/erika-target/debug/macos_native_demo --edr 4 \
  --smoke-seconds "${ERIKA_ADAPTER_SECONDS:-6}" "$media"
