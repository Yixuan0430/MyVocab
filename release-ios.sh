#!/bin/sh
set -eu
cd "$(dirname "$0")"
UPLOAD=1
if [ "${1:-}" = "--archive-only" ]; then
    UPLOAD=0
fi

verify_archive() {
    app_path="$1/Products/Applications/MyVocab.app"
    [ -d "$app_path" ] || { echo "缺少归档 App: $app_path" >&2; exit 1; }
    [ -f "$app_path/PrivacyInfo.xcprivacy" ] || { echo "缺少主应用 PrivacyInfo.xcprivacy" >&2; exit 1; }
    [ -f "$app_path/AnkiCatalogSeed.bin.zst" ] || { echo "缺少 AnkiCatalogSeed.bin.zst" >&2; exit 1; }
    [ -f "$app_path/PlugIns/LexikosWidgets.appex/PrivacyInfo.xcprivacy" ] || { echo "缺少小组件 PrivacyInfo.xcprivacy" >&2; exit 1; }
    enc=$(/usr/libexec/PlistBuddy -c "Print ITSAppUsesNonExemptEncryption" "$app_path/Info.plist" 2>/dev/null || echo "")
    [ "$enc" = "false" ] || { echo "ITSAppUsesNonExemptEncryption 未设为 false: $enc" >&2; exit 1; }
    ent_xml=$(codesign -d --entitlements - --xml "$app_path" 2>/dev/null)
    printf '%s' "$ent_xml" | python3 -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
assert p.get("com.apple.developer.icloud-container-environment") == "Production", p.get("com.apple.developer.icloud-container-environment")
assert "iCloud.com.yixuanwu.lexikos" in (p.get("com.apple.developer.icloud-container-identifiers") or [])
assert "group.com.yixuanwu.lexikos" in (p.get("com.apple.security.application-groups") or []), p.get("com.apple.security.application-groups")
' || { echo "iOS Release 归档权限不符合 App Store Production 要求" >&2; exit 1; }
}

xcodegen generate -q
rm -rf build/Lexikos-iOS.xcarchive build/ios
xcodebuild -project Lexikos.xcodeproj -scheme Lexikos-iOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Lexikos-iOS.xcarchive -allowProvisioningUpdates -quiet archive
verify_archive build/Lexikos-iOS.xcarchive
if [ "$UPLOAD" = "0" ]; then
    echo "Verified archive: build/Lexikos-iOS.xcarchive"
    exit 0
fi
xcodebuild -exportArchive -archivePath build/Lexikos-iOS.xcarchive -exportOptionsPlist Config/ExportOptions-app-store-connect.plist \
    -exportPath build/ios -allowProvisioningUpdates -quiet
echo "Uploaded to App Store Connect."
