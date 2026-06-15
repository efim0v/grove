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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- macOS 26.4 quirk: if this identity's menu-bar layout cache gets corrupted
	     (status item pinned off-screen behind Control Center — hides the icon AND
	     any text title), it clears on a logout/reboot. A fresh bundle id ALSO gets
	     a clean slot, but it re-prompts for the Claude keychain ACL (a new identity
	     isn't trusted) — so we keep the SAME id and clear corruption by relogin,
	     never by bumping the id. -->
	<key>CFBundleIdentifier</key>
	<string>dev.artemefimov.grove</string>
	<key>CFBundleName</key>
	<string>Grove</string>
	<key>CFBundleExecutable</key>
	<string>Grove</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<!-- Keep in sync with GroveVersion.current (Sources/GroveCore/GroveVersion.swift). -->
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>0.2.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Grove controls the cmux terminal to open and switch workspaces.</string>
</dict>
</plist>
PLIST

# Sign with the stable development identity when present so the macOS
# automation (Apple Events -> cmux) consent survives rebuilds: ad-hoc
# signatures change every build, which voids the TCC grant each time.
IDENTITY="Apple Development: Your Name (TEAMID)"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "signed: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (stable identity not found; automation consent will reset on rebuild)"
fi
echo "built: $APP"

if [[ "${1:-}" == "--launch" ]]; then
    open "$APP"
fi
