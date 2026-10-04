#!/bin/bash
# build-appstore.sh
# Builds a distribution-signed archive and exports an App Store Connect IPA.
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 ./build-appstore.sh
#   DEVELOPMENT_TEAM=ABCDE12345 APP_BUNDLE_ID=com.yourteam.aircard ./build-appstore.sh
#
# Then upload the exported IPA with Xcode Organizer, Transporter.app, or:
#   xcrun altool --upload-app -f build/appstore/AirCard-iOS.ipa -t ios \
#     --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
#
# Prereqs:
# - Paid Apple Developer account.
# - App IDs for BOTH the app and its .TunnelProv extension with the
#   "Network Extensions" capability enabled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

TEAM="${DEVELOPMENT_TEAM:-${TEAM_ID:-}}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-}"
EXPORT_METHOD="${EXPORT_METHOD:-app-store-connect}"   # use "app-store" on older Xcode

if [ -z "$TEAM" ]; then
    echo "error: set DEVELOPMENT_TEAM (e.g. DEVELOPMENT_TEAM=ABCDE12345 ./build-appstore.sh)" >&2
    exit 1
fi

BUNDLE_ARGS=()
if [ -n "$APP_BUNDLE_ID" ]; then
    BUNDLE_ARGS+=(APP_BUNDLE_ID="$APP_BUNDLE_ID" TUNNEL_BUNDLE_ID="$APP_BUNDLE_ID.TunnelProv")
fi

rm -rf build/AirCard-iOS.xcarchive build/appstore
mkdir -p build

echo "==> Archiving (Release) for team $TEAM..."
xcodebuild archive \
    -project AirCard-iOS.xcodeproj \
    -scheme AirCard-iOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath build/AirCard-iOS.xcarchive \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"} \
    -allowProvisioningUpdates

cat > build/exportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${EXPORT_METHOD}</string>
    <key>teamID</key>
    <string>${TEAM}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

echo "==> Exporting signed IPA (method=$EXPORT_METHOD)..."
xcodebuild -exportArchive \
    -archivePath build/AirCard-iOS.xcarchive \
    -exportPath build/appstore \
    -exportOptionsPlist build/exportOptions.plist \
    -allowProvisioningUpdates

IPA="$(find build/appstore -name "*.ipa" | head -n 1)"
if [ -z "$IPA" ]; then
    echo "error: no IPA produced in build/appstore" >&2
    exit 1
fi

echo "==> Done: $ROOT/$IPA"
echo
echo "Upload it with one of:"
echo "  - Xcode Organizer (Window > Organizer > Distribute App > App Store Connect)"
echo "  - Transporter.app"
echo "  - xcrun altool --upload-app -f \"$IPA\" -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
