#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
include="$root/crates/mobile/include"
mkdir -p dist
export IPHONEOS_DEPLOYMENT_TARGET=16.0

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target add "$target"
  cargo rustc --locked --release -p betelgeuse-mobile --target "$target" --lib --crate-type staticlib
done

xcodebuild -create-xcframework \
  -library "$root/target/aarch64-apple-ios/release/libbetelgeuse_mobile.a" -headers "$include" \
  -library "$root/target/aarch64-apple-ios-sim/release/libbetelgeuse_mobile.a" -headers "$include" \
  -output "$root/dist/Betelgeuse-Core.xcframework"

BETELGEUSE_CORE_INCLUDE="$include" \
BETELGEUSE_CORE_LIB="$root/target/aarch64-apple-ios/release/libbetelgeuse_mobile.a" \
  bash clients/ios/build.sh
cp clients/ios/Betelgeuse-0.6.0-iPhone-unsigned.ipa dist/
