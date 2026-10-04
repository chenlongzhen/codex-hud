#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/../Codex HUD.app}"
"$root/scripts/swift.sh" build -c release --product CodexHUD
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
"$root/.build/release/CodexHUD" --make-icon "$root/.build/HUD.iconset"
# Replace the inode to avoid a cached macOS signature when rebuilding in place.
rm -f "$app/Contents/MacOS/CodexHUD"
cp "$root/.build/release/CodexHUD" "$app/Contents/MacOS/CodexHUD"
# Remove local object-file paths/debug symbols before signing a distributable app.
/usr/bin/strip -S "$app/Contents/MacOS/CodexHUD"
iconutil -c icns "$root/.build/HUD.iconset" -o "$app/Contents/Resources/HUD.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>CodexHUD</string>
<key>CFBundleIconFile</key><string>HUD</string>
<key>CFBundleIdentifier</key><string>local.codexhud.desktop</string>
<key>CFBundleName</key><string>Codex HUD</string>
<key>CFBundleDisplayName</key><string>Codex HUD</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built: %s\n' "$app"
