#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
include="$root/crates/mobile/include"
mkdir -p dist target/webrtc-ios
archive="$root/target/webrtc-ios/WebRTC-M154.xcframework.zip"
if [[ ! -f "$archive" ]]; then
  curl -fL --retry 3 --connect-timeout 20 -o "$archive" https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip
fi
echo "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16  $archive" | shasum -a 256 -c -
unzip -q -o "$archive" -d target/webrtc-ios
framework="$(find "$root/target/webrtc-ios" -path '*/ios-arm64/WebRTC.framework' -type d -print -quit)"
test -n "$framework"
export IPHONEOS_DEPLOYMENT_TARGET=16.0

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target add "$target"
  cargo rustc --locked --release -p betelgeuse-mobile --target "$target" --lib --crate-type staticlib
done

xcodebuild -create-xcframework \
  -library "$root/target/aarch64-apple-ios/release/libbetelgeuse_mobile.a" -headers "$include" \
  -library "$root/target/aarch64-apple-ios-sim/release/libbetelgeuse_mobile.a" -headers "$include" \
  -output "$root/dist/Betelgeuse-Core.xcframework"

BETELGEUSE_WEBRTC_FRAMEWORK="$framework" \
BETELGEUSE_CORE_INCLUDE="$include" \
BETELGEUSE_CORE_LIB="$root/target/aarch64-apple-ios/release/libbetelgeuse_mobile.a" \
  bash clients/ios/build.sh
cp clients/ios/Betelgeuse-0.8.2-iPhone-unsigned.ipa dist/
