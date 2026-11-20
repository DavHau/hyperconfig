# The two third-party Hermes phone apps, built from their release tags with
# our patches (./README.md says which and why). The APKs come out UNSIGNED
# and zip-aligned: a signature needs the key, which lives in clan vars
# (generator android-app-signing) and so never in the store:
# ../../modules/android-apps.nix signs them on the host and serves them.
#
# Dependencies: gradle's own downloads run through nixpkgs' mitm-cache with
# per-app lock files (deps-<app>.json), recorded against the flake's own
# nixpkgs-android-apps; refresh as ./README.md says (Updating).
{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle_9,
  jdk17_headless,
  jdk21_headless,
  androidenv,
  git,
}:
let
  sdk =
    (androidenv.composeAndroidPackages {
      platformToolsVersion = "37.0.1";
      buildToolsVersions = [
        "36.0.0"
        "37.0.0"
      ];
      platformVersions = [
        "36"
        "37.0"
      ];
      includeEmulator = false;
      includeSystemImages = false;
      includeNDK = false;
    }).androidsdk;
  androidHome = "${sdk}/libexec/android-sdk";

  app =
    {
      pname,
      version,
      src,
      patches,
      jdks,
      task,
      apkGlob,
      deps,
      extraGradleFlags ? [ ],
    }:
    stdenv.mkDerivation (finalAttrs: {
      inherit
        pname
        version
        src
        patches
        ;
      nativeBuildInputs = [
        gradle_9
        jdk21_headless
        git
      ];
      mitmCache = gradle_9.fetchDeps {
        pkg = finalAttrs.finalPackage;
        data = deps;
      };
      # Gradle runs on JDK 21; the app's toolchain (17 or 21) comes from the
      # store, never from foojay's downloader.
      env = {
        JAVA_HOME = jdk21_headless.home;
        ANDROID_HOME = androidHome;
        ANDROID_SDK_ROOT = androidHome;
      };
      gradleFlags = [
        "-Dorg.gradle.java.installations.auto-download=false"
        "-Dorg.gradle.java.installations.auto-detect=false"
        "-Dorg.gradle.java.installations.paths=${lib.concatMapStringsSep "," (j: j.home) jdks}"
        "-Dorg.gradle.configuration-cache=false"
        "-Dorg.gradle.caching=false"
        # The SDK's own aapt2: the one in Maven is a dynamically linked
        # binary for FHS systems.
        "-Pandroid.aapt2FromMavenOverride=${androidHome}/build-tools/37.0.0/aapt2"
      ]
      ++ extraGradleFlags;
      gradleBuildTask = task;
      # Recording the deps runs the real build: the generic nixDownloadDeps
      # resolves every configuration, which AGP's variants refuse.
      gradleUpdateTask = task;
      # Hermes Mobile asks git for the commit it embeds (GIT_SHA).
      preBuild = ''
        git init -q && git -c user.email=b@b -c user.name=b commit -q --allow-empty -m build
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        apk=$(echo ${apkGlob})
        ${androidHome}/build-tools/37.0.0/zipalign -c -P 16 4 "$apk"
        cp "$apk" $out/${pname}-${version}-unsigned.apk
        runHook postInstall
      '';
      dontFixup = true;
      passthru.apk = "${pname}-${version}-unsigned.apk";
      meta.platforms = [ "x86_64-linux" ];
    });
in
{
  hermes-mobile = app {
    pname = "hermes-mobile";
    version = "3.5.3";
    src = fetchFromGitHub {
      owner = "Hy4ri";
      repo = "hermes-mobile";
      tag = "v3.5.3";
      hash = "sha256-JLj9oycW1BDQuTezsBJXCYHVh/wuSm2NpUnN5PLh5BE=";
    };
    # Release signing is ours (the module); upstream's config would demand
    # its CI keystore.
    patches = [
      ./hermes-mobile-keep-socket-on-app-switch.patch
      ./hermes-mobile-unsigned-release.patch
    ];
    jdks = [ jdk21_headless ];
    task = ":app:assembleRelease";
    extraGradleFlags = [
      "-PversionName=3.5.3"
      "-PversionCode=30503"
    ];
    apkGlob = "app/build/outputs/apk/release/app-release-unsigned.apk";
    deps = ./deps-hermes-mobile.json;
  };

  hermes-relay = app {
    pname = "hermes-relay";
    version = "1.19.0";
    src = fetchFromGitHub {
      owner = "Codename-11";
      repo = "hermes-relay";
      tag = "android-v1.19.0";
      hash = "sha256-KZyy8sZo1Wgq3/IhASkBVzIFcdNW0xke4yGx8XCdJrw=";
    };
    patches = [
      ./hermes-relay-keep-composer-on-resume.patch
      ./hermes-relay-unsigned-release.patch
    ];
    jdks = [
      jdk17_headless
      jdk21_headless
    ];
    # The sideload flavor: package com.axiomlabs.hermesrelay.sideload, the
    # one Dave had from the GitHub releases.
    task = ":app:assembleSideloadRelease";
    apkGlob = "app/build/outputs/apk/sideload/release/hermes-relay-*-sideload-release-unsigned.apk";
    deps = ./deps-hermes-relay.json;
  };
}
