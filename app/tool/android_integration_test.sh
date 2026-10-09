#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

#
# Boots an Android emulator (headless) and runs the on-device integration
# tests against it.
#
# Usage:
#   ./tool/android_integration_test.sh                 # default AVD, demo suite
#   ./tool/android_integration_test.sh pixel_6        # specific AVD
#   ./tool/android_integration_test.sh --device-gps   # real-receiver suite;
#                                                      # fixes simulated by the
#                                                      # emulator geo console
#
# Anything that is not a leading AVD name or --device-gps is forwarded to
# `flutter test` (e.g. --dart-define=USE_RUST_ENGINE=true).
#
# Requires ANDROID_HOME (or a local Android SDK) and a created AVD:
#   flutter emulators --launch <avd>
#   avdmanager create avd -n test_phone -k "system-images;android-34;google_apis;x86_64"
#
# Environment:
#   BOOT_TIMEOUT   seconds to wait for the device to boot (default 300)
#   TEST_TIMEOUT   seconds to allow each `flutter test` run (default 900)
#   ARTIFACTS_DIR  where failure artifacts land
#                  (default build/integration-artifacts, relative to app/)
set -euo pipefail

PKG="dev.neurieder.against_yesterday"

# --device-gps selects the device-GPS suite; the rest of the arguments keep
# their original meaning (leading non-flag argument = AVD, rest forwarded).
DEVICE_GPS=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--device-gps" ]; then
    DEVICE_GPS=1
  else
    ARGS+=("$arg")
  fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# A leading non-flag argument names the AVD; anything else is forwarded to
# `flutter test` (e.g. --dart-define=USE_RUST_ENGINE=true).
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  AVD="$1"
  shift
else
  AVD="${ANDROID_AVD:-test_phone}"
fi
# Forwarded-to-flutter args, captured at top level (a function's "$@" would
# shadow these).
FLUTTER_ARGS=("$@")
SERIAL="${ANDROID_SERIAL:-emulator-5554}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-build/integration-artifacts}"

EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"

for bin in "$EMULATOR" "$ADB"; do
  if [ ! -x "$bin" ]; then
    echo "error: not found: $bin" >&2
    exit 1
  fi
done

# GNU timeout ships on Linux and CI; fall back to no limit where it is absent
# so a macOS dev machine can still run the harness.
if command -v timeout >/dev/null 2>&1; then
  TEST_TIMEOUT_CMD=(timeout "$TEST_TIMEOUT")
else
  echo ">> warning: 'timeout' not found; running without a test timeout" >&2
  TEST_TIMEOUT_CMD=()
fi

BOOTS_EMULATOR=0
FEEDER_PID=""
GRANT_PID=""

cleanup() {
  if [ -n "$FEEDER_PID" ]; then
    kill "$FEEDER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$GRANT_PID" ]; then
    kill "$GRANT_PID" >/dev/null 2>&1 || true
  fi
  if [ "$BOOTS_EMULATOR" = "1" ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Boot the AVD headlessly unless a device is already available.
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo ">> Booting AVD '$AVD'..."
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot &
  BOOTS_EMULATOR=1
fi

echo ">> Waiting for device $SERIAL to boot..."
"$ADB" wait-for-device
boot_deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  if [ "$(date +%s)" -ge "$boot_deadline" ]; then
    echo "error: device $SERIAL did not finish booting within ${BOOT_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 2
done
echo ">> Device booted."

# --- Shared helpers ---------------------------------------------------------

# A fresh install is the only reliable isolation between suites: it clears the
# route catalog, activity history and the interrupted-run snapshot, so a run
# cannot inherit the previous suite's saved state. Nothing to uninstall (no
# package yet) is fine.
reset_app_state() {
  "$ADB" -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
}

# Preserves the evidence a red run needs: the app log, a screenshot, and the
# location/permission state. Best-effort — it must never mask the test failure.
collect_artifacts() {
  local name="$1"
  local dir="$ARTIFACTS_DIR/$name"
  mkdir -p "$dir"
  "$ADB" -s "$SERIAL" logcat -d > "$dir/logcat.txt" 2>/dev/null || true
  "$ADB" -s "$SERIAL" exec-out screencap -p > "$dir/screenshot.png" 2>/dev/null || true
  "$ADB" -s "$SERIAL" shell dumpsys location > "$dir/dumpsys-location.txt" 2>/dev/null || true
  "$ADB" -s "$SERIAL" shell dumpsys package "$PKG" > "$dir/dumpsys-package.txt" 2>/dev/null || true
  echo ">> Failure artifacts in $dir" >&2
}

# --- Device-GPS mode: simulated fixes over the emulator geo console ---------
#
# The app runs with USE_DEVICE_GPS=true, so fixes arrive through the real
# geolocator platform channel; the script feeds the emulator's location
# provider at 1 Hz along the start segment of riverLoop (the route the race
# test saves), out-and-back over ~50 m (~5 m/s). Staying on the saved
# route's segment keeps the race axis a real on-route progression instead
# of a projection of a foreign track onto the route.
#
# Emulator 36 quirk (verified on the installed AVD): checksummed NMEA
# sentences over `geo nmea` are accepted with OK but never reach Android's
# location stack — the plain `geo fix <lon> <lat> [alt [satellites]]`
# console command does deliver, including the speed the emulator derives
# from successive fixes.

# riverLoop's first leg (Berlin), where the feeder walks.
SEG_LAT0=52.5050
SEG_LON0=13.3600
SEG_LAT1=52.5095
SEG_LON1=13.3660

# Pushes one simulated position (latitude longitude). Note geo fix takes
# longitude first.
geo_send() {
  local lat="$1" lon="$2"
  "$ADB" -s "$SERIAL" emu geo fix "$lon" "$lat" 500 8 \
    >/dev/null 2>&1 || true
}

# Retries the permission grant until it lands: the package only exists once
# `flutter test` has installed it (a cold Gradle build can take minutes), and
# a reinstall may clear a grant made earlier — the loop heals that before the
# record screen ever asks for permission (an untappable system dialog would
# otherwise wedge the test).
grant_location_loop() {
  while true; do
    if "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 \
      && "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1; then
      echo ">> Location permission granted to $PKG."
      return 0
    fi
    sleep 1
  done
}

# Must be a brace-bodied function, not `() ( ... )`: backgrounding a
# subshell-bodied function forks a wrapper plus a body process, and $! is
# the wrapper — killing it in cleanup would orphan the real loop.
start_feeder() {
  start=$(date +%s)
  while true; do
    t=$(( $(date +%s) - start ))
    phase=$(( t % 20 ))
    if [ "$phase" -le 10 ]; then
      frac=$phase
    else
      frac=$(( 20 - phase ))
    fi
    # Walk the first 8% (~50 m) of the segment out-and-back at 1 Hz.
    lat=$(awk -v a="$SEG_LAT0" -v b="$SEG_LAT1" -v f="$frac" \
      'BEGIN { printf "%.7f", a + (b - a) * f * 0.08 / 10 }')
    lon=$(awk -v a="$SEG_LON0" -v b="$SEG_LON1" -v f="$frac" \
      'BEGIN { printf "%.7f", a + (b - a) * f * 0.08 / 10 }')
    geo_send "$lat" "$lon" >/dev/null 2>&1 || true
    sleep 1
  done
}

run_device_gps_suite() {
  echo ">> Pre-flight: enabling location services..."
  # Cycle the master switch once: it clears last locations and any state a
  # previous run left in the provider — a clean feed must start from an
  # empty stack.
  "$ADB" -s "$SERIAL" shell cmd location set-location-enabled false >/dev/null 2>&1 || true
  sleep 1
  "$ADB" -s "$SERIAL" shell cmd location set-location-enabled true >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell settings put secure location_mode 3 >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" dumpsys location 2>/dev/null | sed -n '1,6p' || true

  # Console probe: a plain `geo fix` must answer OK (KO = bad auth/args).
  local probe
  probe="$("$ADB" -s "$SERIAL" emu geo fix 13.3600 52.5050 500 8 2>&1)" || true
  case "$probe" in
    *OK*) echo ">> Emulator geo console accepted a simulated fix." ;;
    *)
      echo "error: emulator geo console not usable: $probe" >&2
      exit 1
      ;;
  esac

  # Fresh install so this suite starts from an empty catalog/snapshot.
  reset_app_state

  grant_location_loop &
  GRANT_PID=$!
  start_feeder &
  FEEDER_PID=$!

  echo ">> Running the device-GPS integration test on $SERIAL..."
  # REQUIRE_DEVICE_GPS turns a missing/tripped define into a hard failure
  # instead of a silent skip, mirroring REQUIRE_RUST_ENGINE in the host job.
  if ! ${TEST_TIMEOUT_CMD[@]+"${TEST_TIMEOUT_CMD[@]}"} flutter test integration_test/device_gps_test.dart -d "$SERIAL" \
    --dart-define=USE_DEVICE_GPS=true \
    --dart-define=REQUIRE_DEVICE_GPS=true \
    ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}; then
    echo ">> Device-GPS test failed — dumping state:" >&2
    "$ADB" -s "$SERIAL" shell dumpsys location 2>/dev/null | tail -25 || true
    "$ADB" -s "$SERIAL" shell dumpsys package "$PKG" 2>/dev/null \
      | sed -n '/runtime permissions/,/^$/p' || true
    collect_artifacts device-gps
    exit 1
  fi
}

run_demo_suite() {
  # Fresh install so the demo suite records against an empty catalog/history
  # and cannot inherit a previous run's saved route or activity.
  reset_app_state
  echo ">> Running integration tests on $SERIAL..."
  if ! ${TEST_TIMEOUT_CMD[@]+"${TEST_TIMEOUT_CMD[@]}"} flutter test integration_test -d "$SERIAL" \
    ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}; then
    collect_artifacts demo
    exit 1
  fi
}

cd "$(dirname "$0")/.."
if [ "$DEVICE_GPS" = "1" ]; then
  run_device_gps_suite
else
  run_demo_suite
fi
