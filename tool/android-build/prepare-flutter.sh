#!/usr/bin/env bash
# Run inside `nix develop path:tool/android-build` on x86_64-linux.
set -euo pipefail

: "${KIOSK_ANDROID_WORK_DIR:?Set KIOSK_ANDROID_WORK_DIR to a private, writable build directory}"
: "${FLUTTER_LINUX_INTERPRETER:?Enter the project Android devshell first}"

version=3.44.6
expected_sha256=a6320fd72e9a2690c08e2a6a70874a30cb120dee7c78f49d2c628bd7c9e20525
archive="$KIOSK_ANDROID_WORK_DIR/flutter_linux_${version}-stable.tar.xz"
flutter_root="$KIOSK_ANDROID_WORK_DIR/flutter"
url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${version}-stable.tar.xz"

mkdir -p "$KIOSK_ANDROID_WORK_DIR"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 --output "$archive.part" "$url"
  mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c -

if [[ ! -x "$flutter_root/bin/flutter" ]]; then
  tar -C "$KIOSK_ANDROID_WORK_DIR" -xf "$archive"
fi

# The official Linux binaries request /lib64/ld-linux-x86-64.so.2. Patch only
# this extracted copy for NixOS; the SHA-verified archive remains untouched.
count=0
while IFS= read -r binary; do
  interpreter=$(patchelf --print-interpreter "$binary" 2>/dev/null) || continue
  if [[ "$interpreter" == /lib64/ld-linux-x86-64.so.2 ]]; then
    patchelf --set-interpreter "$FLUTTER_LINUX_INTERPRETER" "$binary"
    ((count += 1))
  fi
done < <(find "$flutter_root/bin" -type f -perm /111)

"$flutter_root/bin/flutter" --version
printf 'Flutter executable: %s/bin/flutter (patched %s ELF loaders)\n' "$flutter_root" "$count"
