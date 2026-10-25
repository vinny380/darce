#!/bin/bash
# Recompiles the app icon from its Icon Composer source (Assets/AppIcon.icon) into Assets/Compiled:
# Assets.car (macOS 26 renders it natively, no gray plate) and AppIcon.icns (macOS 14 and 15). Needs Xcode.
# The compiled files are committed so building D'arce doesn't need Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
xcrun actool "$PWD/Assets/AppIcon.icon" --compile "$out" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$out/partial.plist" --target-device mac >/dev/null
mkdir -p Assets/Compiled
cp "$out/Assets.car" "$out/AppIcon.icns" Assets/Compiled/
echo "compiled Assets/Compiled/{Assets.car,AppIcon.icns}"
