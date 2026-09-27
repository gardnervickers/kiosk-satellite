# Household Portal fork: agent operating instructions

This repository is Gardner Vickers's fork of Kiosk Satellite. `origin` should be
`gardnervickers/kiosk-satellite`; upstream is `jxlarrea/kiosk-satellite`. The
household Portal deployment and configuration live in the separate `nixcfg`
repository under `services/portal-kiosk/`. Read its `AGENTS.md`,
`services/portal-kiosk/README.md`, and relevant fleet/voice documentation before
changing a Portal. Do not treat upstream's generic Portal setup guide as a
record of the household's current devices or settings.

## Scope of an installation request

- Building or testing this fork does not authorize installing it on a Portal.
  A request to install or deploy does. Select the exact target Portal(s) and
  inspect their current app version, Android package, signing certificate,
  connection state, and relevant voice behavior first. Never assume every
  Portal is on the same build.
- Do not run the `nixcfg` provisioning script to update an existing Portal:
  it installs a pinned upstream APK. Preserve the current launcher, Home
  Assistant identity, remote-admin settings, microphone grant, and all other
  app data where possible. Do not clear app data, uninstall, change the
  application ID, or modify Android security settings as part of an ordinary
  update.
- If a device is reachable only through remote administration, do not infer
  that it supports sideloading. Portal network ADB normally disappears after
  reboot; use the documented USB/ADB procedure or an explicitly verified
  installation channel.

## Build and signing preflight

1. Start from the intended commit with a clean checkout and record its SHA.
   The upstream release workflow in `.github/workflows/release.yml` pins
   Flutter 3.44.6 and Java 17. From `app/`, run `flutter pub get`, relevant
   tests, then `flutter build apk --release`. The universal APK is
   `app/build/app/outputs/flutter-apk/app-release.apk`. Confirm its package is
   `me.jxl.kiosk_satellite`, its version code, SHA-256, and signing certificate
   with Android build tools (`aapt`/`apkanalyzer` and `apksigner`).
2. Release builds without `app/android/key.properties` fall back to the local
   **debug** signing key (see `app/android/app/build.gradle.kts`). Never assume
   a successful release build is signed for an in-place update. Keep signing
   credentials outside Git and logs. Do not copy upstream's CI secrets or try
   to obtain its private signing key.
3. For each target, use explicit `adb -s SERIAL` commands. Check `adb devices
   -l`, `adb -s SERIAL shell dumpsys package me.jxl.kiosk_satellite` for its
   version, and inspect the installed APK's signer by obtaining its path with
   `adb -s SERIAL shell pm path me.jxl.kiosk_satellite`, pulling that APK to a
   private temporary location, and running `apksigner verify --print-certs`.
   Compare the installed and candidate signer digests. Also ensure the
   candidate version code is not lower than the installed version.
4. Android will reject `adb install -r` if the signer differs. In that case,
   stop before touching the device and report the migration choices. Moving
   from an upstream-signed install to our own signing key generally requires
   an uninstall/reinstall and loses app-private data. A fresh backup from the
   device's Remote Administration **full configuration export** can help
   restore settings and page localStorage, but it is not a guarantee that all
   state survives. Obtain explicit authorization for that migration and plan
   its restore and acceptance checks separately. Never use `adb uninstall`
   or `pm clear` as an automatic fix for a signature failure.

## Install and verify

When preflight confirms a compatible in-place update and installation was
requested, install one Portal at a time using
`adb -s SERIAL install -r PATH_TO_VERIFIED_APK`. Confirm success, read back
the installed version and signer, launch the app if needed, and check its
remote-admin status and Home Assistant connection. On the device, verify
dashboard rendering, microphone permission, native wake detection, first-word
capture, one full spoken turn, reply audio, and wake rearming after the session.
Compare with the preflight behavior before continuing to another Portal.
Report source tests, APK build/signing, ADB installation, live readback, and
physical voice behavior as distinct results. Keep the previous APK and a
private configuration export available for rollback planning; a rollback may
also be blocked by Android version-code and signing rules.

This fork's built-in updater targets upstream releases. Do not trigger or
assume it will retain this fork's changes; inspect update settings and the
installed signer before using any fleet or in-app update mechanism.
