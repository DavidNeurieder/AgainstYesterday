#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

#
# Boots an Android emulator (headless) and runs the on-device integration
# tests against it.
#
# Usage:
#   ./tool/android_integration_test.sh                 # default AVD
#   ./tool/android_integration_test.sh pixel_6        # specific AVD
#
# Requires ANDROID_HOME (or a local Android SDK) and a created AVD:
#   flutter emulators --launch <avd>
#   avdmanager create avd -n test_phone -k "system-images;android-34;google_apis;x86_64"
set -euo pipefail

# A leading non-flag argument names the AVD; anything else is forwarded to
# `flutter test` (e.g. --dart-define=USE_RUST_ENGINE=true).
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  AVD="$1"
  shift
else
  AVD="${ANDROID_AVD:-test_phone}"
fi
SERIAL="${ANDROID_SERIAL:-emulator-5554}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"

EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"

for bin in "$EMULATOR" "$ADB"; do
  if [ ! -x "$bin" ]; then
    echo "error: not found: $bin" >&2
    exit 1
  fi
done

cleanup() {
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}

# Boot the AVD headlessly unless a device is already available.
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo ">> Booting AVD '$AVD'..."
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot &
  trap cleanup EXIT
fi

echo ">> Waiting for device $SERIAL to boot..."
"$ADB" wait-for-device
until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 2
done
echo ">> Device booted."

echo ">> Running integration tests on $SERIAL..."
cd "$(dirname "$0")/.."
flutter test integration_test -d "$SERIAL" "$@"