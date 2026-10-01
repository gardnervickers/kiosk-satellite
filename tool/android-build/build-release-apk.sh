#!/usr/bin/env bash
# Run inside `nix develop path:tool/android-build` on x86_64-linux.
set -euo pipefail
umask 077

: "${KIOSK_ANDROID_WORK_DIR:?Set KIOSK_ANDROID_WORK_DIR to the prepared private build directory}"
: "${KIOSK_SOURCE_DIR:?Set KIOSK_SOURCE_DIR to an isolated Git checkout}"
: "${KIOSK_EXPECTED_COMMIT:?Set KIOSK_EXPECTED_COMMIT to the reviewed Git SHA}"
: "${KIOSK_EXPECTED_VERSION:?Set KIOSK_EXPECTED_VERSION to the reviewed version name}"
: "${KIOSK_EXPECTED_BUILD:?Set KIOSK_EXPECTED_BUILD to the reviewed version code}"
[[ "$KIOSK_EXPECTED_BUILD" =~ ^[0-9]+$ && "$KIOSK_EXPECTED_VERSION" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || {
  printf 'Invalid expected APK version or build.\n' >&2; exit 1;
}

signing_dir=${KIOSK_SIGNING_DIR:-/home/gvickers/.local/share/kiosk-satellite/signing}
keystore=$signing_dir/release.p12
password_file=$signing_dir/release.password
flutter=$KIOSK_ANDROID_WORK_DIR/flutter/bin/flutter
apk_dir=$KIOSK_SOURCE_DIR/app/build/app/outputs/flutter-apk
key_properties=$KIOSK_SOURCE_DIR/app/android/key.properties

[[ $(git -C "$KIOSK_SOURCE_DIR" rev-parse HEAD) == "$KIOSK_EXPECTED_COMMIT" ]] || {
  printf 'Source checkout does not match reviewed commit.\n' >&2; exit 1;
}
[[ -z $(git -C "$KIOSK_SOURCE_DIR" status --porcelain) ]] || {
  printf 'Source checkout is not clean.\n' >&2; exit 1;
}
grep -Fx "version: $KIOSK_EXPECTED_VERSION+$KIOSK_EXPECTED_BUILD" \
  "$KIOSK_SOURCE_DIR/app/pubspec.yaml" >/dev/null || {
  printf 'Reviewed version does not match pubspec.yaml.\n' >&2; exit 1;
}
[[ -f "$keystore" && -f "$password_file" ]] || {
  printf 'Protected signing identity is missing.\n' >&2; exit 1;
}
[[ -x "$flutter" ]] || { printf 'Pinned Flutter SDK is missing.\n' >&2; exit 1; }
"$flutter" --version | head -1 | grep -F 'Flutter 3.44.6' >/dev/null

export ANDROID_HOME=$KIOSK_ANDROID_WORK_DIR/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export GRADLE_USER_HOME=$KIOSK_ANDROID_WORK_DIR/gradle-cache
export PUB_CACHE=$KIOSK_ANDROID_WORK_DIR/pub-cache
export XDG_CACHE_HOME=$KIOSK_ANDROID_WORK_DIR/xdg-cache
export TMPDIR=$KIOSK_ANDROID_WORK_DIR
export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH=$KIOSK_ANDROID_WORK_DIR/flutter/bin:$PATH
mkdir -p "$GRADLE_USER_HOME" "$PUB_CACHE" "$XDG_CACHE_HOME"

# AGP's Maven aapt2 requests /lib64/ld-linux-x86-64.so.2 and cannot start on
# NixOS. Use the matching SDK's Nix-patched aapt2 without editing source.
aapt2_override="android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/36.0.0/aapt2"
gradle_properties=$GRADLE_USER_HOME/gradle.properties
if [[ -e "$gradle_properties" ]]; then
  grep -Fx "$aapt2_override" "$gradle_properties" >/dev/null || {
    printf 'Existing Gradle properties lack the required NixOS aapt2 override.\n' >&2
    exit 1
  }
else
  printf '%s\n' "$aapt2_override" > "$gradle_properties"
fi

# Gradle's release configuration reads this ignored file. Its password exists
# only in this owner-only RAM checkout, never in shell arguments or Nix store.
[[ ! -e "$key_properties" ]] || {
  printf 'Refusing to replace an existing key.properties.\n' >&2; exit 1;
}
python3 - "$key_properties" "$keystore" "$password_file" <<'PY'
import os
import pathlib
import sys

properties, keystore, password_file = map(pathlib.Path, sys.argv[1:])
password = password_file.read_text().strip()
fd = os.open(properties, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as output:
    output.write(f'storeFile={keystore}\n')
    output.write('keyAlias=gardner-kiosk-satellite\n')
    output.write(f'storePassword={password}\nkeyPassword={password}\n')
PY
trap 'rm -f "$key_properties"' EXIT

cd "$KIOSK_SOURCE_DIR/app"
"$flutter" pub get
[[ -z $(git -C "$KIOSK_SOURCE_DIR" status --porcelain) ]] || {
  printf 'Dependency resolution changed tracked source; inspect before building.\n' >&2; exit 1;
}
apk="$apk_dir/app-arm64-v8a-release.apk"
# A previous build in this checkout must not satisfy the output checks.
rm -f "$apk"
"$flutter" build apk --release --split-per-abi \
  --build-name="$KIOSK_EXPECTED_VERSION" --build-number="$KIOSK_EXPECTED_BUILD"

[[ -f "$apk" ]] || { printf 'Missing APK: %s\n' "$apk" >&2; exit 1; }
cert=$(
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$apk" \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p'
)
[[ "$cert" == 6d45121818ad5e5b617f61f59cd21b317374a5d59759a058edb6dfcc0a8edbc0 ]] || {
  printf 'Unexpected APK signer for %s\n' "$apk" >&2; exit 1;
}
package=$("$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging "$apk" | grep '^package:')
[[ "$package" == *"name='me.jxl.kiosk_satellite'"* &&
   "$package" == *"versionCode='$KIOSK_EXPECTED_BUILD'"* &&
   "$package" == *"versionName='$KIOSK_EXPECTED_VERSION'"* ]] || {
  printf 'Unexpected package/version for %s\n' "$apk" >&2; exit 1;
}
printf 'certificate_sha256=%s\n%s\n' "$cert" "$package"
sha256sum "$apk"
