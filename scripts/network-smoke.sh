#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
run_dir=$(mktemp -d "$PWD/artifacts/network-smoke.XXXXXX")
smoke_bundle="$run_dir/D'arce.app"
bash scripts/build.sh "$smoke_bundle"
python3 scripts/run-native-smoke.py \
  --mode network \
  --executable "$smoke_bundle/Contents/MacOS/BrowserPrototype" \
  --run-dir "$run_dir" \
  --timeout 120
