{
  description = "Project-scoped Android APK build tools for Kiosk Satellite";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/aca4d95fce4914b3892661bcb80b8087293536c6";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.android_sdk.accept_license = true;
        config.allowUnfree = true;
      };
      android = pkgs.androidenv.composeAndroidPackages {
        platformVersions = [ "36" ];
        buildToolsVersions = [ "36.0.0" ];
        platformToolsVersion = "36.0.0";
        includeNDK = true;
        ndkVersions = [ "28.2.13676358" ];
        includeCmake = true;
        cmakeVersions = [ "3.22.1" ];
        includeEmulator = false;
        includeSystemImages = false;
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          android.androidsdk
          curl
          git
          jdk17
          nodejs
          patchelf
          python3
          unzip
          xz
        ];
        JAVA_HOME = pkgs.jdk17;
        ANDROID_HOME = "${android.androidsdk}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${android.androidsdk}/libexec/android-sdk";
        FLUTTER_LINUX_INTERPRETER = pkgs.stdenv.cc.bintools.dynamicLinker;
      };
    };
}
