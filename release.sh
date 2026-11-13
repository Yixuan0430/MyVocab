#!/bin/sh
# Build a signed, notarized MyVocab-<version>.dmg in dist/, through Xcode so the CloudKit
# provisioning profile is embedded. Needs XcodeGen, a "Developer ID Application" certificate
# and a notarytool keychain profile:
#   xcrun notarytool store-credentials lexikos-notary --apple-id <id> --team-id BGM8P5U985
set -e
VERSION=1.1.0
PROFILE="${NOTARY_PROFILE:-lexikos-notary}"
xcodegen generate -q
rm -rf build/MyVocab.xcarchive build/MyVocab.app
xcodebuild -project Lexikos.xcodeproj -scheme Lexikos-macOS -configuration Release \
    -destination 'generic/platform=macOS' -archivePath build/MyVocab.xcarchive -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath build/MyVocab.xcarchive -exportOptionsPlist Config/ExportOptions-developer-id.plist \
    -exportPath build -allowProvisioningUpdates -quiet
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MyVocab.app/Contents/Info.plist)
[ "$ACTUAL_VERSION" = "$VERSION" ] || { echo "版本不一致" >&2; exit 1; }
DMG="dist/MyVocab-$VERSION.dmg"
mkdir -p dist && rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R build/MyVocab.app "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MyVocab" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "${SIGN_ID:-Developer ID Application}" "$DMG"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
else
    echo "未配置公证凭据：$PROFILE，正式发布未完成" >&2
    exit 1
fi
(cd dist && shasum -a 256 "MyVocab-$VERSION.dmg" > "MyVocab-$VERSION.dmg.sha256")
echo "$DMG"
