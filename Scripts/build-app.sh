#!/bin/zsh
# Builds dist/Grove.app from the GroveApp release binary.
# Usage: Scripts/build-app.sh [--launch]
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product GroveApp

APP="dist/Grove.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GroveApp "$APP/Contents/MacOS/Grove"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.artem.grove</string>
	<key>CFBundleName</key>
	<string>Grove</string>
	<key>CFBundleExecutable</key>
	<string>Grove</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<!-- Keep in sync with GroveVersion.current (Sources/GroveCore/GroveVersion.swift). -->
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--launch" ]]; then
    open "$APP"
fi
