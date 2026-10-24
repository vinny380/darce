#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
run_dir=$(mktemp -d "$PWD/artifacts/smoke.XXXXXX")
smoke_bundle="$run_dir/D'arce.app"
bash scripts/build.sh "$smoke_bundle"
python3 - "$smoke_bundle" "$run_dir" <<'PY_GUARD'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] = 'io.github.vinny380.darce.smoke.' + pathlib.Path(sys.argv[2]).name.split('.')[-1].lower()
info['BrowserVerificationDataDirectory'] = str(pathlib.Path(sys.argv[2]).resolve())
path.write_bytes(plistlib.dumps(info))
PY_GUARD
codesign --force --sign - "$smoke_bundle"
python3 scripts/run-native-smoke.py \
  --mode native \
  --executable "$smoke_bundle/Contents/MacOS/BrowserPrototype" \
  --run-dir "$run_dir" \
  --timeout 45
