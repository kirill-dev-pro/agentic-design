#!/bin/sh
# Wraps a built binary into "Agentic Design.app" and packs it for release.
#
#   tools/release/bundle.sh <binary> <out-dir>
#
# The version comes from the binary itself (`--version`, src/version.odin), so Info.plist
# can never disagree with the code. Signing: with DEVELOPER_ID set (a "Developer ID
# Application: ..." identity in the keychain) the bundle is signed with the hardened runtime
# and a timestamp, ready for notarization; otherwise ad-hoc (`codesign -s -`), which Apple
# Silicon requires to run at all. Writes:
#   <out-dir>/Agentic Design.app
#   <out-dir>/Agentic-Design-<version>-arm64.zip   (what the updater downloads)
#   <out-dir>/Agentic-Design-<version>-arm64.dmg   (for a first install; skip with NO_DMG=1)
#
# PACK_ONLY=1 skips building and signing and only packs <out-dir>/Agentic Design.app again
# (after notarization staples it).
set -eu
BIN=$1
OUT=$2
cd "$(dirname "$0")/../.."
VERSION=$("$BIN" --version)
NAME="Agentic Design"
APP="$OUT/$NAME.app"
if [ -z "${PACK_ONLY:-}" ]; then
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/samples"
cp "$BIN" "$APP/Contents/MacOS/agentic-design"
cp assets/icon/AppIcon.icns "$APP/Contents/Resources/"
cp designs/sample-screens.pen designs/sample.lib.pen "$APP/Contents/Resources/samples/"
cp assets/LICENSE-lucide.txt assets/fonts/OFL-NotoSans.txt THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>agentic-design</string>
	<key>CFBundleIdentifier</key><string>dev.kcrz.agentic-design</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSArchitecturePriority</key><array><string>arm64</string></array>
	<key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<key>NSHumanReadableCopyright</key><string>Agentic Design, agentic-design.kcrz.dev</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>Pen document</string>
			<key>CFBundleTypeExtensions</key><array><string>pen</string></array>
			<key>CFBundleTypeRole</key><string>Editor</string>
			<key>LSHandlerRank</key><string>Alternate</string>
		</dict>
	</array>
</dict>
</plist>
PLIST
if [ -n "${DEVELOPER_ID:-}" ]; then
	codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
	codesign --force --sign - "$APP"
fi
fi
codesign --verify --deep --strict "$APP"
ZIP="$OUT/Agentic-Design-$VERSION-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ -z "${NO_DMG:-}" ]; then
	DMG="$OUT/Agentic-Design-$VERSION-arm64.dmg"
	STAGE=$(mktemp -d)
	ditto "$APP" "$STAGE/$NAME.app"
	ln -s /Applications "$STAGE/Applications"
	rm -f "$DMG"
	hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
	rm -rf "$STAGE"
	if [ -n "${DEVELOPER_ID:-}" ]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"; fi
fi
echo "$NAME $VERSION -> $OUT"
