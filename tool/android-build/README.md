# Garage pilot APK build

This directory contains an x86_64-linux build shell for the reviewed Garage
pilot. It matches the release workflow's Flutter 3.44.6 and Java 17, and pins
Android SDK 36, build tools 36.0.0, NDK 28.2.13676358, and CMake 3.22.1.
Nothing here installs an APK or changes a Portal.

The Nix shell is project scoped. From the repository root, use
`nix develop path:tool/android-build`. The shell accepts the Android SDK
license declaratively and provides the SDK, Java, Node, and build utilities.
The official Flutter archive is downloaded separately into a writable build
directory and checked against its published SHA-256 before extraction. The
extracted copy's Linux ELF loaders are patched for NixOS; the verified archive
is left intact.

The following commands run **inside** the shell. Choose a private work
directory with enough space for the Flutter archive, extracted SDK, Gradle
cache, dependency cache, and APK outputs. On the workstation, a private
directory under `/dev/shm` avoids filling its nearly full root filesystem.

```sh
export KIOSK_ANDROID_WORK_DIR=/dev/shm/kiosk-android-build
install -d -m 700 "$KIOSK_ANDROID_WORK_DIR"
bash tool/android-build/prepare-flutter.sh
bash tool/android-build/prepare-sdk-overlay.sh
export ANDROID_HOME="$KIOSK_ANDROID_WORK_DIR/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
yes | "$KIOSK_ANDROID_WORK_DIR/flutter/bin/flutter" doctor --android-licenses
"$KIOSK_ANDROID_WORK_DIR/flutter/bin/flutter" doctor -v
```

Flutter's license check invokes `sdkmanager` without an SDK root argument.
The overlay routes that check to its own writable license files while the SDK
packages remain linked to Nix store paths. Verify that doctor reports
**All Android licenses accepted**.

Build from an isolated, clean GitHub checkout of the reviewed commit:

```sh
git clone --depth 1 https://github.com/gardnervickers/kiosk-satellite.git \
  "$KIOSK_ANDROID_WORK_DIR/source"
export KIOSK_SOURCE_DIR="$KIOSK_ANDROID_WORK_DIR/source"
export KIOSK_EXPECTED_COMMIT=REVIEWED_FULL_GIT_SHA
export KIOSK_EXPECTED_VERSION=2026.10.2
export KIOSK_EXPECTED_BUILD=294
bash tool/android-build/build-release-apk.sh
```

The build script checks the exact source SHA and clean tree, then builds
`app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. It verifies package
`me.jxl.kiosk_satellite`, the expected version/code from `pubspec.yaml`, the
fork signer, and the APK's SHA-256. Supply reviewed values for each release.

The signing identity lives only on the workstation at
`/home/gvickers/.local/share/kiosk-satellite/signing/release.p12`, with its
password in `release.password` beside it. The directory is 0700 and both
files are 0600. Build credentials are read into an ignored 0600
`app/android/key.properties` in the private RAM checkout, then removed on
normal script exit. Never put the keystore, password, or properties file in
Git, Nix store, logs, or an APK. The public signing certificate SHA-256 is
`6d45121818ad5e5b617f61f59cd21b317374a5d59759a058edb6dfcc0a8edbc0`.
The owner should make a separate, encrypted backup of **both** signing files
and verify that they can be restored. Losing either prevents future in-place
updates signed with this identity.

An APK build and valid signature do not authorize installation. Compare the
candidate's signer with the target's installed signer before an in-place
update. A different signer requires a separately approved migration and
configuration restore, with physical checks.
