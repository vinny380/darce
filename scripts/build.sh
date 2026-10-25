#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# > 1 )); then
  printf '%s\n' 'Usage: build.sh [output-bundle.app]' >&2
  exit 2
fi
# Resolve relative output paths from this project directory before writing files.
default_app="$PWD/artifacts/D'arce.app"
app=$(python3 - "${1:-$default_app}" <<'PY_OUTPUT'
import pathlib, sys
path = pathlib.Path(sys.argv[1]).expanduser().resolve()
if path.suffix != '.app':
    raise SystemExit('Output bundle must have an .app suffix.')
if path.exists() and not path.is_dir():
    raise SystemExit('Output bundle exists and is not a directory.')
print(path)
PY_OUTPUT
)
# CONFIG=release for distributable builds; debug keeps local iteration fast.
config=${CONFIG:-debug}
swift build -c "$config" --product BrowserPrototype
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/BrowserPrototype" "$app/Contents/MacOS/BrowserPrototype"
mkdir -p "$app/Contents/Resources"
cp Assets/Compiled/Assets.car Assets/Compiled/AppIcon.icns "$app/Contents/Resources/"   # scripts/icon.sh rebuilds these
python3 - "$app" <<'PY'
import os, plistlib, pathlib, sys
app = pathlib.Path(sys.argv[1])
info = {
    'CFBundleName': "D'arce",
    'CFBundleDisplayName': "D'arce",
    'CFBundleIdentifier': 'io.github.vinny380.darce',
    'CFBundleExecutable': 'BrowserPrototype',
    'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'AppIcon',
    'CFBundleIconName': 'AppIcon',
    'CFBundleShortVersionString': os.environ.get('VERSION', '0.1.0'),
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
    'NSCameraUsageDescription': 'Websites you approve can use your camera for video calls and recording.',
    'NSMicrophoneUsageDescription': 'Websites you approve can use your microphone for calls and recording.',
    'NSLocationUsageDescription': 'Websites you approve can use your location for maps and nearby results.',
    # A browser loads any site, including plain-http ones; App Transport Security would block those silently.
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoadsInWebContent': True},
}
# Lets macOS offer D'arce as the default browser. Smoke bundles leave it out so test copies don't pile up there.
if os.environ.get('WEB_HANDLER') == '1':
    info['CFBundleURLTypes'] = [{'CFBundleURLName': 'Web site URL', 'CFBundleURLSchemes': ['http', 'https']}]
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app"
printf '%s\n' "$app"
