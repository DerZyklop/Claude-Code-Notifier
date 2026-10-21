#!/bin/bash
# Builds "build/Claude Code Notifier.app". Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# The temporary files of all tools go into .build, not into the system temp folder.
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

SDK="${SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | tail -1)}"

# A new version only when all unit tests in Tests/ pass. SwiftPM gets a home folder in .build for its caches and
# settings. Only the native build system passes TMPDIR on to the compiler.
CFFIXED_USER_HOME="$PWD/.build/home" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SDKROOT="$SDK" \
	swift test --build-system native

APP="build/Claude Code Notifier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -sdk "$SDK" -module-cache-path .build/module-cache -O -parse-as-library -swift-version 5 \
	-target "$(uname -m)-apple-macos13.0" \
	Sources/*.swift \
	-o "$APP/Contents/MacOS/ClaudeCodeNotifier"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.claude-code-notifier.app</string>
	<key>CFBundleName</key><string>Claude Code Notifier</string>
	<key>CFBundleDisplayName</key><string>Claude Code Notifier</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleExecutable</key><string>ClaudeCodeNotifier</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# A new build number for each build. Notification Center reloads the icon and name of an app when it changes.
sed -i '' "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" "$APP/Contents/Info.plist"

# The app icon, in all sizes that macOS asks for.
ICON_WORK=$(mktemp -d "$TMPDIR/icon.XXXXXX")
swiftc -sdk "$SDK" -module-cache-path .build/module-cache make-icon.swift -o "$ICON_WORK/make-icon"
"$ICON_WORK/make-icon" "$ICON_WORK/icon.png"
mkdir "$ICON_WORK/AppIcon.iconset"
for points in 16 32 128 256 512; do
	sips -z $points $points "$ICON_WORK/icon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${points}x${points}.png" >/dev/null
	sips -z $((points * 2)) $((points * 2)) "$ICON_WORK/icon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# The notification chimes. Notifications only find sounds in the app bundle or in ~/Library/Sounds.
cp /System/Library/Sounds/{Purr,Bottle}.aiff "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
echo "Built $APP"
