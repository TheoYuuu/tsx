#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_output="$PWD/.build/QA/SelectionFixture.app"
qa_sdk="$(xcrun --sdk macosx --show-sdk-path)"
qa_arch="$(uname -m)"
mkdir -p "$qa_output/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -target "$qa_arch-apple-macos15.0" -sdk "$qa_sdk" -O \
    Tools/QA/SelectionFixture.swift -o "$qa_output/Contents/MacOS/SelectionFixture"
cat > "$qa_output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.theoyuuu.LumaxTranslate.SelectionFixture</string>
<key>CFBundleName</key><string>Lumax Selection Fixture</string>
<key>CFBundleExecutable</key><string>SelectionFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
plutil -lint "$qa_output/Contents/Info.plist"
codesign --force --sign - --options runtime "$qa_output"
codesign --verify --strict "$qa_output"
"$qa_output/Contents/MacOS/SelectionFixture" --self-test
printf 'Built fixture; not launched for interaction: %s\n' "$qa_output"
