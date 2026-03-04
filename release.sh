#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building Mistglow universal release binary..."

# Clean previous release build
rm -rf .build/release-arm64 .build/release-x86_64 release

# Build for both architectures
swift build -c release --arch arm64 --scratch-path .build/release-arm64 2>&1
swift build -c release --arch x86_64 --scratch-path .build/release-x86_64 2>&1

# Create universal binary
echo "Creating universal binary..."
mkdir -p release/Mistglow.app/Contents/MacOS
mkdir -p release/Mistglow.app/Contents/Resources
lipo -create \
    .build/release-arm64/release/Mistglow \
    .build/release-x86_64/release/Mistglow \
    -output release/Mistglow.app/Contents/MacOS/Mistglow

# Copy bundle resources
cp Mistglow.app/Contents/Info.plist release/Mistglow.app/Contents/Info.plist
cp -R Mistglow.app/Contents/Resources/ release/Mistglow.app/Contents/Resources/ 2>/dev/null || true

# Ad-hoc sign
echo "Ad-hoc code signing..."
codesign --force --sign - --entitlements Mistglow.entitlements --deep release/Mistglow.app

# Create zip for GitHub Releases
echo "Creating release zip..."
cd release
zip -r ../Mistglow-macOS-universal.zip Mistglow.app
cd ..

# Show results
echo ""
echo "Done! Release artifacts:"
ls -lh Mistglow-macOS-universal.zip
echo ""
file release/Mistglow.app/Contents/MacOS/Mistglow
echo ""
echo "Upload Mistglow-macOS-universal.zip to GitHub Releases."
echo "Users will need to run: xattr -cr Mistglow.app"
