#!/bin/bash
# Publishes a new version that installed copies pick up through Sparkle.
#
#   1. Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and commit.
#   2. ./release.sh "- What changed" "- Another change"
#
# Builds, signs the update archive with the Sparkle key in ~/.iscreen-signing, creates the
# GitHub release, then publishes appcast.xml (only after the download exists).
set -euo pipefail
cd "$(dirname "$0")"

[ $# -gt 0 ] || { echo 'Usage: ./release.sh "- What changed" ["- Another change" …]'; exit 1; }
NOTES=$(printf '%s\n' "$@")
REPO="lyubomiriliev/iscreen"
KEY="$HOME/.iscreen-signing/sparkle_private_key"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist; }
VERSION=$(plist CFBundleShortVersionString)
BUILD_NUMBER=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
TAG="v$VERSION"

[ -f "$KEY" ] || { echo "Missing Sparkle key at $KEY"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "$TAG already exists — bump the version in Resources/Info.plist."
  exit 1
fi

./build.sh
ZIP="build/iScreen-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/iScreen.app "$ZIP"
SIGNATURE=$(Vendor/Sparkle/bin/sign_update --ed-key-file "$KEY" "$ZIP")
URL="https://github.com/$REPO/releases/download/$TAG/iScreen-$VERSION.zip"

git push origin HEAD
gh release create "$TAG" "$ZIP" build/iScreen.dmg --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "iScreen $VERSION" --notes "$NOTES"

python3 -I scripts/add_appcast_item.py appcast.xml "$VERSION" "$BUILD_NUMBER" "$MIN_OS" "$URL" "$SIGNATURE" "$NOTES"
git add appcast.xml
git commit -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin HEAD

echo "✓ Released iScreen $VERSION"
echo "  Download for new users: https://github.com/$REPO/releases/latest/download/iScreen.dmg"
