#!/bin/bash
# Downloads the pinned Sparkle release into Vendor/Sparkle (not committed to git).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.10.0"
DEST="Vendor/Sparkle"
[ -d "$DEST/Sparkle.framework" ] && exit 0

mkdir -p "$DEST"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "Vendor/Sparkle-$VERSION.tar.xz"
tar -xJf "Vendor/Sparkle-$VERSION.tar.xz" -C "$DEST"
rm "Vendor/Sparkle-$VERSION.tar.xz"
echo "Sparkle $VERSION → $DEST"
