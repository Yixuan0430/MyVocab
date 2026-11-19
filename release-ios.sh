#!/bin/sh
set -eu
cd "$(dirname "$0")"
xcodegen generate -q
rm -rf build/Lexikos-iOS.xcarchive
xcodebuild -project Lexikos.xcodeproj -scheme Lexikos-iOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Lexikos-iOS.xcarchive -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath build/Lexikos-iOS.xcarchive -exportOptionsPlist Config/ExportOptions-app-store-connect.plist \
    -exportPath build/ios -allowProvisioningUpdates -quiet
echo "Uploaded; it appears in TestFlight after Apple finishes processing."
