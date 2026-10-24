#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
run_dir=$(mktemp -d "$PWD/artifacts/window-lifecycle.XXXXXX")
smoke_bundle="$run_dir/Browser Window Lifecycle.app"
bash scripts/build.sh "$smoke_bundle"
python3 - "$smoke_bundle" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] = 'io.github.vinny380.darce.window-lifecycle.' + pathlib.Path(sys.argv[1]).parent.name.split('.')[-1].lower()
info['CFBundleDisplayName'] = 'Browser Window Lifecycle'
info['BrowserVerificationDataDirectory'] = str(pathlib.Path(sys.argv[1]).parent.resolve())
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$smoke_bundle"
python3 scripts/run-native-smoke.py \
  --mode window-lifecycle \
  --executable "$smoke_bundle/Contents/MacOS/BrowserPrototype" \
  --run-dir "$run_dir" \
  --timeout 900
