#!/bin/bash
# Rebuilds "Picull.app" in this folder. Run: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Picull.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

compile() {
    swiftc -O -swift-version 5 -parse-as-library "$@" \
        -target "$(uname -m)-apple-macos14.0" \
        Sources/*.swift -o "$APP/Contents/MacOS/Picull" 2>build.log
}

# The macOS 27 SDK needs a SwiftUI plugin that only comes with full Xcode.
# Without Xcode, fall back to the newest older SDK that is installed.
if ! compile; then
    built=""
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2[0-6]*.sdk 2>/dev/null | sort -rV); do
        if compile -sdk "$sdk"; then built="$sdk"; break; fi
    done
    if [ -z "$built" ]; then
        grep "error:" build.log || cat build.log
        exit 1
    fi
fi
rm -f build.log

cp Info.plist "$APP/Contents/Info.plist"
# This folder syncs with iCloud, which adds file attributes that block signing.
# Clear them first. If signing still fails the app runs anyway (the compiler
# already signs the program inside it).
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "Note: could not re-sign the bundle; the app still runs."
echo "Built: $(pwd)/$APP"
