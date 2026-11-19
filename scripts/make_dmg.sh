#!/bin/zsh
# Packages build/Ligature.app into build/Ligature-<version>.dmg: the app, an Applications shortcut to drag it onto,
# the licence and a short "read me first" about opening an app that isn't notarised.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/Ligature.app ]] || ./scripts/build_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Ligature.app/Contents/Info.plist)
STAGE=build/dmg-stage
DMG=build/Ligature-$VERSION.dmg
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R build/Ligature.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cat > "$STAGE/Read Me First.txt" <<TXT
Ligature $VERSION, made by Mithin Sagar (mithinsagarofficial@gmail.com)

1. Drag Ligature onto the Applications folder.
2. Open Ligature from Applications. macOS will say it can't check it for malicious software, because the app
   isn't notarised by Apple. Open System Settings > Privacy & Security, scroll down and click "Open Anyway"
   next to the Ligature message, then confirm. You only need to do this once.
3. Install a TeX engine once: brew install tectonic
   (Tectonic downloads only the packages your documents need. MacTeX's latexmk also works.)
   For Word export, also: brew install pandoc

Ligature runs on your Mac with no account. It only goes online when the TeX engine fetches a package
for the first time, or when you look up a citation by DOI, arXiv ID or title.

MIT License (LICENSE.txt).
TXT
hdiutil create -volname "Ligature $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null && echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
