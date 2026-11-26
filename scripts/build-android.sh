#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
: "${ANDROID_HOME:?Android SDK required}"
: "${ANDROID_NDK_HOME:?Android NDK required}"
: "${JAVA_HOME:?JDK required}"
host="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
if [[ "$host" == darwin ]]; then arch=x86_64; fi
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host-$arch/bin"
mkdir -p dist target/mobile-android/lib
for target in aarch64-linux-android x86_64-linux-android; do
  case "$target" in
    aarch64-linux-android) abi=arm64-v8a ;;
    x86_64-linux-android) abi=x86_64 ;;
  esac
  rustup target add "$target"
  shell_target="${target//-/_}"
  upper_target="$(printf '%s' "$shell_target" | tr '[:lower:]' '[:upper:]')"
  env "CARGO_TARGET_${upper_target}_LINKER=$toolchain/${target}29-clang" \
      "CC_${shell_target}=$toolchain/${target}29-clang" \
      "AR_${shell_target}=$toolchain/llvm-ar" \
      cargo rustc --locked --release -p betelgeuse-mobile --target "$target" --lib --crate-type cdylib
  mkdir -p "target/mobile-android/lib/$abi"
  cp "target/$target/release/libbetelgeuse_mobile.so" "target/mobile-android/lib/$abi/"
done

BETELGEUSE_NATIVE_LIBS="$root/target/mobile-android" BETELGEUSE_UNSIGNED=1 bash clients/android/build.sh
cp clients/android/Betelgeuse-0.6.0-Android-unsigned.apk dist/
