#!/bin/bash
# Builds a downloadable release: dist/<name>-<version>.dmg and .zip (Apple Silicon only).
# Set SIGN_IDENTITY ("Developer ID Application: …") and NOTARY_PROFILE (a
# `xcrun notarytool store-credentials` profile) to sign + notarize; without them
# the app is ad-hoc signed and users must approve it in Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-0.1.0}
name="D'arce"
dist="$PWD/dist"
app="$dist/$name.app"
rm -rf "$dist" && mkdir -p "$dist"
CONFIG=release VERSION="$version" bash scripts/build.sh "$app" >/dev/null

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
fi

base="$dist/Darce-$version-arm64"
ditto -c -k --keepParent "$app" "$base.zip"
staging=$(mktemp -d)
cp -R "$app" "$staging/" && ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "$name" -srcfolder "$staging" -format UDZO "$base.dmg"
rm -rf "$staging"

if [[ -n ${SIGN_IDENTITY:-} && -n ${NOTARY_PROFILE:-} ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$base.dmg"
  xcrun notarytool submit "$base.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$base.dmg"
  # The zip's app has the same signature, so Gatekeeper finds its ticket online.
fi
shasum -a 256 "$base.zip" "$base.dmg"
