#!/bin/bash
set -euo pipefail

# Builds AirCard-iOS (with the embedded TunnelProv network extension) into an IPA.
#
# Signed build (recommended for the built-in loopback tunnel):
#   DEVELOPMENT_TEAM=ABCDE12345 ./build-ipa.sh
#   DEVELOPMENT_TEAM=ABCDE12345 APP_BUNDLE_ID=com.yourteam.aircard ./build-ipa.sh
#
# Unsigned build (sign it yourself with TrollStore / a certificate):
#   ./build-ipa.sh
#
# Note: the embedded packet tunnel needs the Network Extension entitlement, which
# free-account sideloads cannot sign. Use a paid developer account or TrollStore.

CONFIG="${1:-Release}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

TEAM="${DEVELOPMENT_TEAM:-${TEAM_ID:-}}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-}"

echo "==> Building AirCard-iOS ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

COMMON_ARGS=(
  -project AirCard-iOS.xcodeproj
  -scheme AirCard-iOS
  -configuration "$CONFIG"
  -derivedDataPath build/DerivedData
  -destination 'generic/platform=iOS'
)

BUNDLE_ARGS=()
if [ -n "$APP_BUNDLE_ID" ]; then
  BUNDLE_ARGS+=(APP_BUNDLE_ID="$APP_BUNDLE_ID" TUNNEL_BUNDLE_ID="$APP_BUNDLE_ID.TunnelProv")
fi

if [ -n "$TEAM" ]; then
  echo "==> Signing with DEVELOPMENT_TEAM=$TEAM (app + TunnelProv extension)"
  xcodebuild "${COMMON_ARGS[@]}" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"} \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    clean build
else
  echo "==> No DEVELOPMENT_TEAM set: producing an UNSIGNED IPA."
  xcodebuild "${COMMON_ARGS[@]}" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"} \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    clean build
fi

APP_PATH="$(find build/DerivedData/Build/Products -name "AirCard-iOS.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: AirCard-iOS.app not found in DerivedData"
    exit 1
fi

if [ ! -d "$APP_PATH/PlugIns/TunnelProv.appex" ]; then
    echo "Error: TunnelProv.appex was not embedded in AirCard-iOS.app"
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" build/AirCard-iOS.app

if [ -z "$TEAM" ]; then
    # Clean any existing signature for the unsigned flow.
    rm -rf build/AirCard-iOS.app/_CodeSignature
    rm -rf build/AirCard-iOS.app/embedded.mobileprovision
fi

mkdir -p build/Payload
cp -R build/AirCard-iOS.app build/Payload/AirCard-iOS.app

cd build
zip -qr "AirCard-iOS.ipa" Payload
rm -rf Payload AirCard-iOS.app

echo "==> Done! IPA generated at: $ROOT/build/AirCard-iOS.ipa"
ls -lh "$ROOT/build/AirCard-iOS.ipa"
