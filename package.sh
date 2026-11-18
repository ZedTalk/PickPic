#!/bin/bash
# Builds a shareable zip: Picull.app (Apple silicon + Intel) and the quickstart PDF.
# Run: ./package.sh     Output: Picull-<version>-beta.zip in this folder.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NAME="Picull $VERSION beta"
ZIP="$HERE/Picull-$VERSION-beta.zip"

# Build outside this iCloud-synced folder: iCloud adds file attributes that break signing.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/picull-package.XXXXXX")
APP="$WORK/$NAME/Picull.app"
mkdir -p "$APP/Contents/MacOS"

# The macOS 27 SDK needs a SwiftUI plugin that only comes with full Xcode,
# so without Xcode use the newest older SDK that is installed.
SDK_ARGS=()
if ! xcode-select -p | grep -q "Xcode"; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2[0-6]*.sdk | sort -rV | head -1)
    SDK_ARGS=(-sdk "$SDK")
fi

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library "${SDK_ARGS[@]}" \
        -target "$arch-apple-macos14.0" Sources/*.swift -o "$WORK/Picull-$arch" 2>"$WORK/build-$arch.log" \
        || { grep "error:" "$WORK/build-$arch.log"; exit 1; }
done
lipo -create "$WORK/Picull-arm64" "$WORK/Picull-x86_64" -output "$APP/Contents/MacOS/Picull"
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

cp "Picull Quickstart.pdf" "$WORK/$NAME/"
xattr -cr "$WORK/$NAME"
rm -f "$ZIP"
ditto -c -k --keepParent "$WORK/$NAME" "$ZIP"
echo "Packaged: $ZIP"
echo "Work folder (safe to delete): $WORK"
