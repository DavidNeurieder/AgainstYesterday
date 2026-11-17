#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the release APK from a fixed absolute source path.
#
# Dart's AOT compiler embeds the absolute URI of Flutter's generated
# `dart_plugin_registrant.dart` in libapp.so. A local checkout and F-Droid's
# buildserver therefore produced different libapp.so files even when the
# toolchains and inputs were identical. Copying the source tree to a canonical
# path before invoking Flutter removes that last builder-specific string; the
# resulting APK is byte-identical across machines.
#
# Usage:
#   ./app/tool/repro_build.sh                       # uses `flutter` from PATH
#   FLUTTER_BIN=/opt/flutter/bin/flutter ./app/tool/repro_build.sh
#   REPRO_BUILD_ROOT=/tmp/custom ./app/tool/repro_build.sh
#
# The APK is copied back to the normal Flutter output path so this script can
# be dropped into the existing local and F-Droid build flows.
set -euo pipefail

FLUTTER_BIN="${1:-${FLUTTER_BIN:-flutter}}"
ABI="${ABI:-arm64-v8a}"
CANONICAL_ROOT="${REPRO_BUILD_ROOT:-/tmp/against-yesterday-repro-build}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_APP="${CANONICAL_ROOT}/app"
APK_REL="app/build/app/outputs/flutter-apk/app-release.apk"

case "${ABI}" in
  arm64-v8a) TARGET_PLATFORM="android-arm64" ;;
  armeabi-v7a) TARGET_PLATFORM="android-arm" ;;
  x86_64) TARGET_PLATFORM="android-x64" ;;
  *) echo "error: unsupported ABI '${ABI}'" >&2; exit 2 ;;
esac

export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${REPO_ROOT}" log -1 --format=%ct 2>/dev/null || echo 0)}"

echo ">> Reproducible build root: ${CANONICAL_ROOT}"
rm -rf "${CANONICAL_ROOT}"
mkdir -p "${CANONICAL_ROOT}"

# A fresh copy keeps prior build outputs, generated registrants and Rust
# artifacts from leaking into the APK. Native cdylibs are rebuilt below.
tar -C "${REPO_ROOT}" \
  --exclude=.git \
  --exclude=target \
  --exclude=build \
  --exclude=release \
  --exclude=Download \
  --exclude=data/raw \
  --exclude=app/.dart_tool \
  --exclude=app/build \
  --exclude=app/.flutter-plugins-dependencies \
  --exclude=app/android/app/src/main/jniLibs \
  -cf - . | tar -C "${CANONICAL_ROOT}" -xf -

# Patches cached plugin sources (GMS removal, jni build ID). Idempotent.
bash "${CANONICAL_APP}/tool/fdroid_prebuild.sh"

(
  cd "${CANONICAL_ROOT}"
  ABIS="${ABI}" bash app/tool/build_rust_engine_android.sh
  cd app
  "${FLUTTER_BIN}" pub get --enforce-lockfile
  "${FLUTTER_BIN}" build apk --release --target-platform "${TARGET_PLATFORM}"
)

mkdir -p "${REPO_ROOT}/app/build/app/outputs/flutter-apk"
cp "${CANONICAL_ROOT}/${APK_REL}" "${REPO_ROOT}/${APK_REL}"
echo ">> APK: ${REPO_ROOT}/${APK_REL}"
sha256sum "${REPO_ROOT}/${APK_REL}"
