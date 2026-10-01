#!/usr/bin/env bash
# Run inside `nix develop path:tool/android-build` on x86_64-linux.
set -euo pipefail

: "${KIOSK_ANDROID_WORK_DIR:?Set KIOSK_ANDROID_WORK_DIR to a private, writable build directory}"
: "${ANDROID_HOME:?Enter the project Android devshell first}"

source_sdk=$ANDROID_HOME
overlay=$KIOSK_ANDROID_WORK_DIR/android-sdk
mkdir -p "$overlay/licenses"

for category in build-tools cmake cmdline-tools ndk platforms; do
  mkdir -p "$overlay/$category"
  for component in "$source_sdk/$category"/*; do
    ln -sfn "$component" "$overlay/$category/${component##*/}"
  done
done
for component in ndk-bundle platform-tools tools; do
  ln -sfn "$source_sdk/$component" "$overlay/$component"
done
for license in "$source_sdk/licenses"/*; do
  if [[ ! -f "$overlay/licenses/${license##*/}" ]]; then
    cp -L "$license" "$overlay/licenses/${license##*/}"
  fi
done

# Flutter runs sdkmanager without --sdk_root when checking licenses. The real
# binary lives under /nix/store, so point that one invocation at our writable
# overlay rather than accidentally checking the store's immutable licenses.
mkdir -p "$overlay/cmdline-tools/latest/bin"
cat > "$overlay/cmdline-tools/latest/bin/sdkmanager" <<EOF
#!/bin/sh
exec "$source_sdk/cmdline-tools/19.0/bin/sdkmanager" --sdk_root="$overlay" "\$@"
EOF
chmod +x "$overlay/cmdline-tools/latest/bin/sdkmanager"

printf 'Project Android SDK overlay: %s\n' "$overlay"
printf 'Set ANDROID_HOME and ANDROID_SDK_ROOT to this path for Flutter and Gradle.\n'
