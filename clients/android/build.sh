#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
export PATH="$JAVA_HOME/bin:$PATH"
tools="$ANDROID_HOME/build-tools/34.0.0"
platform="$ANDROID_HOME/platforms/android-34/android.jar"
mkdir -p build/classes build/dex build/generated
"$tools/aapt2" compile --dir res -o build/resources.zip
"$tools/aapt2" link -o build/base.apk -I "$platform" --manifest AndroidManifest.xml \
  --java build/generated --min-sdk-version 29 --target-sdk-version 34 --version-code 6 --version-name 0.6.0 build/resources.zip
find src build/generated -name '*.java' > build/sources.txt
javac --release 11 -classpath "$platform" -d build/classes @build/sources.txt
find build/classes -name '*.class' > build/classes.txt
"$tools/d8" --lib "$platform" --min-api 29 --output build/dex @build/classes.txt
cp build/base.apk build/unsigned.apk
: "${BETELGEUSE_NATIVE_LIBS:?Set directory containing lib/ABI/libbetelgeuse_mobile.so}"
native_directory="$(cd "$BETELGEUSE_NATIVE_LIBS" && pwd)"
apk_path="$(pwd)/build/unsigned.apk"
(cd "$native_directory" && zip -q -r "$apk_path" lib)
(cd build/dex && zip -q -X ../unsigned.apk classes.dex)
"$tools/zipalign" -f 4 build/unsigned.apk build/aligned.apk

if [[ "${BETELGEUSE_UNSIGNED:-0}" == 1 ]]; then
  cp build/aligned.apk Betelgeuse-0.6.0-Android-unsigned.apk
  exit 0
fi

# Keep this keystore private. Reuse it to sign updates to this beta package.
keystore="${BETELGEUSE_KEYSTORE:-$PWD/build/betelgeuse-beta.p12}"
passfile="${BETELGEUSE_SIGNING_PASSWORD_FILE:-$PWD/build/betelgeuse-beta.pass}"
if [[ ! -f "$keystore" ]]; then
  if [[ ! -f "$passfile" ]]; then
    (umask 077; openssl rand -hex 24 > "$passfile")
  fi
  (umask 077; keytool -genkeypair -keystore "$keystore" -storetype PKCS12 -storepass:file "$passfile" \
    -alias betelgeuse -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Betelgeuse Beta')
fi
"$tools/apksigner" sign --ks "$keystore" --ks-key-alias betelgeuse --ks-pass "file:$passfile" \
  --v4-signing-enabled false --out Betelgeuse-0.6.0-Android.apk build/aligned.apk
"$tools/apksigner" verify --verbose Betelgeuse-0.6.0-Android.apk
