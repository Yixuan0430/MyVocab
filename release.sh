#!/bin/sh
set -eu
cd "$(dirname "$0")"
VERSION=1.2.0
PROFILE="${NOTARY_PROFILE:-lexikos-notary}"
NOTARIZE=1
if [ "${1:-}" = "--export-only" ]; then
    NOTARIZE=0
fi

verify_app() {
    app_path="$1"
    actual_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Contents/Info.plist")
    [ "$actual_version" = "$VERSION" ] || { echo "版本不一致: $actual_version != $VERSION" >&2; exit 1; }
    codesign --verify --deep --strict "$app_path"
    codesign -dvvv "$app_path" 2>&1 | grep -q "Authority=Developer ID Application:" || {
        echo "主应用未使用 Developer ID Application 签名" >&2
        exit 1
    }
    archs=$(lipo -archs "$app_path/Contents/MacOS/MyVocab")
    case " $archs " in
        *" arm64 "* ) ;;
        * ) echo "主应用缺少 arm64 架构: $archs" >&2; exit 1 ;;
    esac
    case " $archs " in
        *" x86_64 "* ) ;;
        * ) echo "主应用缺少 x86_64 架构: $archs" >&2; exit 1 ;;
    esac
    ent=$(codesign -d --entitlements - --xml "$app_path" 2>/dev/null)
    printf '%s' "$ent" | python3 -c '
import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
assert data.get("com.apple.developer.icloud-container-environment") == "Production", data.get("com.apple.developer.icloud-container-environment")
assert "iCloud.com.yixuanwu.lexikos" in (data.get("com.apple.developer.icloud-container-identifiers") or []), data.get("com.apple.developer.icloud-container-identifiers")
assert "CloudKit" in (data.get("com.apple.developer.icloud-services") or []), data.get("com.apple.developer.icloud-services")
assert data.get("com.apple.developer.aps-environment") == "production", data.get("com.apple.developer.aps-environment")
' || {
        echo "主应用 CloudKit / APNs 正式环境权限校验失败" >&2
        exit 1
    }
    profile_path="$app_path/Contents/embedded.provisionprofile"
    [ -f "$profile_path" ] || { echo "缺少 embedded.provisionprofile，其他 Mac 无法启用 CloudKit" >&2; exit 1; }
    decoded=$(security cms -D -i "$profile_path" 2>/dev/null)
    if printf '%s' "$decoded" | grep -q "<key>ProvisionedDevices</key>"; then
        echo "embedded.provisionprofile 绑定了特定设备 UDID，无法在其他 Mac 运行" >&2
        exit 1
    fi
    widget="$app_path/Contents/PlugIns/LexikosWidgets.appex"
    if [ -d "$widget" ]; then
        codesign -dvvv "$widget" 2>&1 | grep -q "Authority=Developer ID Application:" || {
            echo "Widget 扩展未使用 Developer ID Application 签名" >&2
            exit 1
        }
        widget_archs=$(lipo -archs "$widget/Contents/MacOS/LexikosWidgets")
        case " $widget_archs " in
            *" arm64 "* ) ;;
            * ) echo "Widget 缺少 arm64 架构: $widget_archs" >&2; exit 1 ;;
        esac
        case " $widget_archs " in
            *" x86_64 "* ) ;;
            * ) echo "Widget 缺少 x86_64 架构: $widget_archs" >&2; exit 1 ;;
        esac
    fi
}

xcodegen generate -q
rm -rf build/MyVocab.xcarchive build/MyVocab.app
xcodebuild -project Lexikos.xcodeproj -scheme Lexikos-macOS -configuration Release \
    -destination 'generic/platform=macOS' -archivePath build/MyVocab.xcarchive -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath build/MyVocab.xcarchive -exportOptionsPlist Config/ExportOptions-developer-id.plist \
    -exportPath build -allowProvisioningUpdates -quiet
verify_app build/MyVocab.app

if [ "$NOTARIZE" -eq 0 ]; then
    echo "build/MyVocab.app"
    exit 0
fi

DMG="dist/MyVocab-$VERSION.dmg"
mkdir -p dist
rm -f "$DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/MyVocab.app "$STAGE/MyVocab.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MyVocab" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$DMG"
rm -rf "$STAGE"
SIGN_IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$SIGN_IDENTITY" ] || { echo "未找到 Developer ID Application 证书" >&2; exit 1; }
codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "未配置公证凭据：$PROFILE，正式发布未完成" >&2
    exit 1
fi
(cd dist && shasum -a 256 "MyVocab-$VERSION.dmg" > "MyVocab-$VERSION.dmg.sha256")
echo "$DMG"
