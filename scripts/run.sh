#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
open -n "artifacts/D'arce.app" --args --data-dir "$PWD/.local"
