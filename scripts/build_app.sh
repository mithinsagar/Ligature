#!/bin/zsh
# Builds build/Ligature.app: release binary, bundled templates, icon and Info.plist, signed with a stable local
# identity (scripts/make_signing_identity.sh) or ad hoc if that isn't available.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Ligature.app
VERSION="${LIGATURE_VERSION:-1.0.0}"
swift build -c release --product Ligature
BIN=$(swift build -c release --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ligature" "$APP/Contents/MacOS/Ligature"
# Templates and other resources live directly in Contents/Resources (see AppResources).
cp -R Sources/Ligature/Resources/ "$APP/Contents/Resources/"

ICONSET=build/Ligature.iconset; rm -rf $ICONSET; mkdir -p $ICONSET
swift scripts/make_icon.swift build/icon_1024.png
for sz in 16 32 128 256 512; do
  sips -z $sz $sz build/icon_1024.png --out $ICONSET/icon_${sz}x${sz}.png >/dev/null
  sips -z $((sz*2)) $((sz*2)) build/icon_1024.png --out $ICONSET/icon_${sz}x${sz}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ligature</string>
  <key>CFBundleDisplayName</key><string>Ligature</string>
  <key>CFBundleIdentifier</key><string>local.ligature.Ligature</string>
  <key>CFBundleExecutable</key><string>Ligature</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Made by Mithin Sagar</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>LaTeX Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>tex</string><string>ltx</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict></plist>
PLIST

KC="$PWD/.signing/ligature-signing.keychain-db"
[[ -f "$KC" ]] || ./scripts/make_signing_identity.sh >/dev/null 2>&1 || true
if [[ -f "$KC" ]] && security unlock-keychain -p "$(cat .signing/keychain-password)" "$KC" 2>/dev/null; then
  codesign --force --deep --keychain "$KC" --sign "Ligature Local Signing" "$APP"
else
  echo "! signing ad hoc"
  codesign --force --deep --sign - "$APP"
fi
echo "✓ built $APP"
