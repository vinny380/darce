#!/bin/bash
# Publishes a release: builds the DMG and zip, creates the GitHub release, and points the Homebrew cask
# (vinny380/homebrew-tap) at the new DMG.
#   scripts/release.sh <version> [notes.md]
# Without a notes file, GitHub writes the notes from the merged changes. Checksums are appended either way.
# DRY_RUN=1 builds and shows the cask change, but publishes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release.sh <version> [notes.md]}
notes=${2:-}
tag="v$version"
dry=${DRY_RUN:-0}

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first." >&2; exit 1; }
git fetch -q origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "HEAD must match origin/main (push first)." >&2; exit 1; }
if gh release view "$tag" >/dev/null 2>&1; then echo "$tag already exists." >&2; exit 1; fi

VERSION="$version" bash scripts/package.sh
dmg="dist/Darce-$version-arm64.dmg"
zip="dist/Darce-$version-arm64.zip"
dmg_sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
zip_sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

body=$(mktemp)
[[ -n $notes ]] && cat "$notes" > "$body"
printf '\n**Checksums (SHA-256)**\n- `%s` `%s`\n- `%s` `%s`\n' "$(basename "$dmg")" "$dmg_sha" "$(basename "$zip")" "$zip_sha" >> "$body"

# Homebrew: the cask's version and checksum follow the DMG.
tap=$(mktemp -d)
gh repo clone vinny380/homebrew-tap "$tap" -- -q
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$dmg_sha\"/" "$tap/Casks/darce.rb"

if [[ $dry == 1 ]]; then
  echo "DRY RUN: would publish $tag with:"; cat "$body"
  echo "DRY RUN: cask change:"; git -C "$tap" diff
  exit 0
fi

if [[ -n $notes ]]; then
  gh release create "$tag" "$dmg" "$zip" --target main --title "D'arce $version" --notes-file "$body"
else
  gh release create "$tag" "$dmg" "$zip" --target main --title "D'arce $version" --generate-notes --notes-file "$body"
fi
git -C "$tap" commit -qam "darce $version"
git -C "$tap" push -q
echo "Released $tag. brew install --cask vinny380/tap/darce now installs $version."
