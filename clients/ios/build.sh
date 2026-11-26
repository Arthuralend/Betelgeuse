#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-device}"
rm -rf build/sim build/device build/ipa
mkdir -p build

if [ "$MODE" = "simulator" ]; then
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  TARGET="arm64-apple-ios16.0-simulator"
  OUT="build/sim/Supernova.app"
  CACHE="$PWD/.tmp/modulecache-sim"
else
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  TARGET="arm64-apple-ios16.0"
  OUT="build/device/Supernova.app"
  CACHE="$PWD/.tmp/modulecache"
fi

mkdir -p "$OUT" "$CACHE"
: "${BETELGEUSE_CORE_INCLUDE:?Set path to core headers}"
: "${BETELGEUSE_CORE_LIB:?Set path to platform static library}"
cp Info.plist "$OUT/Info.plist"
cp Supernova/AppIcon*.png Supernova/ring.wav "$OUT/"

swiftc -parse-as-library -sdk "$SDK" -target "$TARGET" -O -swift-version 5 \
  -I "$BETELGEUSE_CORE_INCLUDE" -module-cache-path "$CACHE" -Xcc -fmodules-cache-path="$CACHE" \
  -framework SwiftUI -framework MultipeerConnectivity -framework CryptoKit \
  -framework Security -framework Network -framework UserNotifications -framework AVFoundation -framework UIKit \
  -framework SystemConfiguration -framework CoreFoundation -lresolv -lc++ \
  -o "$OUT/Supernova" \
  Supernova/SupernovaApp.swift Supernova/ContentView.swift \
  Supernova/MeshService.swift Supernova/CryptoBox.swift Supernova/Keychain.swift Supernova/CallAudio.swift Supernova/LocalNotifications.swift \
  Supernova/DirectIdentity.swift Supernova/DirectProfile.swift Supernova/DirectLink.swift Supernova/DirectSession.swift Supernova/DirectView.swift Supernova/RelayTunnel.swift Supernova/RustNetworkView.swift "$BETELGEUSE_CORE_LIB"

if [ "$MODE" != "simulator" ]; then
  mkdir -p build/ipa/Payload
  cp -R "$OUT" build/ipa/Payload/
  rm -f Betelgeuse-0.6.0-iPhone-unsigned.ipa
  (cd build/ipa && zip -qry ../../Betelgeuse-0.6.0-iPhone-unsigned.ipa Payload)
  echo "Built: $(pwd)/Betelgeuse-0.6.0-iPhone-unsigned.ipa"
else
  echo "Built: $(pwd)/$OUT"
fi
