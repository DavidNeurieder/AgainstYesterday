#!/usr/bin/env bash
#
# Cross-compiles the `gps-engine` cdylib for Android and installs it into the
# Flutter app's jniLibs tree, so a build with
# `--dart-define=USE_RUST_ENGINE=true` can resolve the bare library name
# `libgps_engine.so` through the platform loader (§6).
#
# Usage:
#   ./tool/build_rust_engine_android.sh                 # arm64-v8a + x86_64
#   ABIS=arm64-v8a ./tool/build_rust_engine_android.sh  # a single ABI
#   ANDROID_API_LEVEL=26 ./tool/build_rust_engine_android.sh
#
# Then build/run the app against the real engine:
#   flutter run   --dart-define=USE_RUST_ENGINE=true
#   flutter build apk --release --dart-define=USE_RUST_ENGINE=true
#
# Requires: an Android SDK with an NDK installed, and `rustup target add` for
# every ABI listed in $ABIS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JNI_LIBS="$REPO_ROOT/app/android/app/src/main/jniLibs"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
# 24 is Flutter's default minSdkVersion (FlutterExtension.kt).
API="${ANDROID_API_LEVEL:-24}"
ABIS="${ABIS:-arm64-v8a x86_64}"

# Maps an Android ABI directory name to its Rust target triple.
target_for_abi() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7-linux-androideabi" ;;
    x86_64) echo "x86_64-linux-android" ;;
    *) echo "" ;;
  esac
}

# The NDK ships one clang wrapper per (triple, API level), e.g.
# aarch64-linux-android24-clang, prebuilt for the host platform.
host_tag() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) echo "error: unsupported host $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "error: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac
  echo "$os-$arch"
}

NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
  # Newest installed NDK wins; any recent one can package a plain cdylib.
  NDK="$(ls -d "$SDK"/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
fi
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  echo "error: no Android NDK found. Install one via Android Studio, or set" >&2
  echo "       ANDROID_NDK_HOME=/path/to/ndk/<version>" >&2
  exit 1
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$(host_tag)/bin"
echo ">> NDK:  $NDK"
echo ">> API:  $API"
echo ">> ABIs: $ABIS"

BUILT=()
for abi in $ABIS; do
  target="$(target_for_abi "$abi")"
  if [ -z "$target" ]; then
    echo "error: unsupported ABI '$abi' (arm64-v8a, armeabi-v7a, x86_64)" >&2
    exit 1
  fi

  if ! rustup target list --installed | grep -qx "$target"; then
    echo "error: Rust target $target is not installed." >&2
    echo "       rustup target add $target" >&2
    exit 1
  fi

  linker="$TOOLCHAIN/$target$API-clang"
  if [ ! -x "$linker" ]; then
    echo "error: NDK linker not found: $linker" >&2
    echo "       (this NDK may not support API level $API — try ANDROID_API_LEVEL=24)" >&2
    exit 1
  fi

  # Cargo reads the linker from the environment, which keeps the NDK path out
  # of any committed .cargo/config.toml.
  linker_var="CARGO_TARGET_$(echo "$target" | tr 'a-z-' 'A-Z_')_LINKER"

  echo ">> Building $abi ($target)..."
  (cd "$REPO_ROOT" && env "$linker_var=$linker" cargo build --release -p gps-engine --target "$target")

  dest="$JNI_LIBS/$abi"
  mkdir -p "$dest"
  install -m 644 "$REPO_ROOT/target/$target/release/libgps_engine.so" "$dest/libgps_engine.so"
  BUILT+=("$abi ($(du -h "$dest/libgps_engine.so" | cut -f1))")
done

echo
echo ">> Installed:"
for entry in "${BUILT[@]}"; do
  echo "     app/android/app/src/main/jniLibs/$entry/libgps_engine.so"
done
echo
echo "Done. Build the app with the real engine:"
echo "  cd app && flutter run --dart-define=USE_RUST_ENGINE=true"
