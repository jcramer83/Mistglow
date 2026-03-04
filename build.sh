#!/bin/bash
set -e
cd "$(dirname "$0")"

# Kill running instance
killall -9 Mistglow 2>/dev/null || true
sleep 1

# Build
swift build 2>&1

# Ensure app bundle exists in /Applications
if [ ! -d /Applications/Mistglow.app ]; then
    cp -R Mistglow.app /Applications/Mistglow.app
    echo "Installed app bundle to /Applications"
fi

# Update only the binary in-place (preserves TCC grants)
cp .build/debug/Mistglow /Applications/Mistglow.app/Contents/MacOS/Mistglow

# Update Info.plist and entitlements if changed
cp Mistglow.app/Contents/Info.plist /Applications/Mistglow.app/Contents/Info.plist
cp -R Mistglow.app/Contents/Resources/ /Applications/Mistglow.app/Contents/Resources/ 2>/dev/null || true

# Ad-hoc code sign
codesign --force --sign - --entitlements Mistglow.entitlements --deep /Applications/Mistglow.app 2>&1

echo "Build complete. Launching..."
open /Applications/Mistglow.app
