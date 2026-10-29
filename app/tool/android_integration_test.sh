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
#   ./tool/android_integration_test.sh --map-smoke    # real MapLibre map smoke
#                                                      # (nightly-only: network)
#   ./tool/android_integration_test.sh --permissions  # Android location
#                                                      # permission states
#   ./tool/android_integration_test.sh --process-death # real process-death
#                                                      # recovery (two processes)
#   ./tool/android_integration_test.sh --smoke        # record-and-save journey
#                                                      # only (old-API jobs)
#
# Anything that is not a leading AVD name, --device-gps, --map-smoke,
# --permissions, --process-death or --smoke is forwarded to `flutter test`
# (e.g. --dart-define=USE_RUST_ENGINE=true).
#
# Requires ANDROID_HOME (or a local Android SDK) and a created AVD:
#   flutter emulators --launch <avd>
#   avdmanager create avd -n test_phone -k "system-images;android-34;google_apis;x86_64"
#
# Environment:
#   BOOT_TIMEOUT   seconds to wait for the device to boot (default 300)
#   TEST_TIMEOUT   seconds to allow each `flutter test` run (default 900)
#   EMULATOR_GPU   emulator -gpu mode when the script boots the AVD
#                  (default swiftshader_indirect; use `host` on a machine with
#                  a real GPU — software rendering provokes systemui ANRs)
#   ARTIFACTS_DIR  where failure artifacts land
#                  (default build/integration-artifacts, relative to app/)
set -euo pipefail

PKG="dev.neurieder.against_yesterday"

# --device-gps selects the device-GPS suite, --map-smoke the real MapLibre map
# smoke, and --smoke narrows the demo suite to its record-and-save journey;
# the rest of the arguments keep their original meaning (leading non-flag
# argument = AVD, rest forwarded).
DEVICE_GPS=0
MAP_SMOKE=0
SMOKE=0
PERMISSIONS=0
PROCESS_DEATH=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --device-gps) DEVICE_GPS=1 ;;
    --map-smoke) MAP_SMOKE=1 ;;
    --smoke) SMOKE=1 ;;
    --permissions) PERMISSIONS=1 ;;
    --process-death) PROCESS_DEATH=1 ;;
    *) ARGS+=("$arg") ;;
  esac
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
DISMISS_PID=""
WATCHER_PID=""
PD_RUN_PID=""

cleanup() {
  if [ -n "$FEEDER_PID" ]; then
    kill "$FEEDER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$GRANT_PID" ]; then
    kill "$GRANT_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$DISMISS_PID" ]; then
    kill "$DISMISS_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$PD_RUN_PID" ]; then
    kill "$PD_RUN_PID" >/dev/null 2>&1 || true
  fi
  if [ "$BOOTS_EMULATOR" = "1" ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    # Wait for the emulator to actually leave adb before exiting. Back-to-back
    # suites run in one CI job (full, device-gps, permissions, process-death),
    # and a following suite that still sees the dying serial skips its own boot
    # and then waits out BOOT_TIMEOUT for a device that is busy shutting down.
    local i
    for ((i = 0; i < 90; i++)); do
      if ! "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
}
trap cleanup EXIT

# Boot the AVD headlessly unless the target device is already available. Scoped
# to $SERIAL: with another emulator attached, a bare `adb get-state` reports a
# device while $SERIAL may be absent, and every later command then fails with
# "more than one device/emulator".
if ! "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
  echo ">> Booting AVD '$AVD'..."
  # SwiftShader is the portable default (CI runners have no usable GPU). On a
  # host with a real GPU, `EMULATOR_GPU=host` avoids the systemui ANRs that
  # software rendering produces — an ANR window takes focus and silently
  # swallows taps and keyevents.
  #
  # A non-default serial implies the port: without `-port`, a second suite on
  # the same host always boots onto 5554, shares the device with the first, and
  # the two runs steal each other's foreground window (which shows up as
  # unrelated apps launching mid-drive and taps landing nowhere).
  BOOT_ARGS=()
  case "$SERIAL" in
    emulator-[0-9]*) BOOT_ARGS+=(-port "${SERIAL#emulator-}") ;;
  esac
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu "${EMULATOR_GPU:-swiftshader_indirect}" -no-snapshot \
    ${BOOT_ARGS[@]+"${BOOT_ARGS[@]}"} &
  BOOTS_EMULATOR=1
fi

echo ">> Waiting for device $SERIAL to boot..."
# Scoped to $SERIAL: with a second device attached (another emulator or a
# plugged-in phone) a bare `wait-for-device` returns immediately and every
# later command fails with "more than one device/emulator".
"$ADB" -s "$SERIAL" wait-for-device
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

# Suppresses the system's own crash/ANR dialogs. Under software rendering
# systemui occasionally ANRs, and an "Application Not Responding" window takes
# focus away from the app — which silently swallows both the harness's BACK
# keyevents and `tester.tap`. Never showing them keeps the device focused on
# the test.
hide_system_dialogs() {
  "$ADB" -s "$SERIAL" shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell settings put secure anr_show_background 0 >/dev/null 2>&1 || true
}

# A fresh install is the only reliable isolation between suites: it clears the
# route catalog, activity history and the interrupted-run snapshot, so a run
# cannot inherit the previous suite's saved state. Nothing to uninstall (no
# package yet) is fine.
reset_app_state() {
  "$ADB" -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
}

# --- Real-app UI automation --------------------------------------------------
#
# The process-death suite drives the *installed* app (outside `flutter test`,
# which uninstalls the package on exit — see run_process_death_suite). These
# helpers speak to it through uiautomator, the same accessibility tree a human
# sees, so a tap is a real touch at the node's centre.

# Dumps the current window's uiautomator XML to stdout.
ui_dump() {
  "$ADB" -s "$SERIAL" exec-out uiautomator dump /dev/tty 2>/dev/null \
    | sed -n 's/.*<?xml/<?xml/p'
}

# Prints "cx cy" for the first node whose text or content-desc equals $1, or
# exits non-zero when it is absent. Only leaves with empty bounds (invisible
# containers) are skipped.
ui_center_of() {
  local label="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  ui_dump | python3 -c '
import re, sys
label = sys.argv[1]
xml = sys.stdin.read()
for m in re.finditer(r"<node[^>]*>", xml):
    tag = m.group(0)
    def attr(name):
        mm = re.search(name + r"=\"([^\"]*)\"", tag)
        return mm.group(1) if mm else ""
    if attr("text") != label and attr("content-desc") != label:
        # Flutter merges the label into its content-desc, often as
        # "Label&#10;<child copy>"; accept a line equal to the label.
        desc = attr("content-desc").replace("&#10;", "\n")
        if not any(line.strip() == label for line in desc.split("\n")):
            continue
    bounds = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    if not bounds:
        continue
    x1, y1, x2, y2 = (int(bounds.group(i)) for i in range(1, 5))
    if x2 <= x1 or y2 <= y1:
        continue
    print((x1 + x2) // 2, (y1 + y2) // 2)
    sys.exit(0)
sys.exit(1)
' "$label"
}

# Prints the centre of the first node with label $1 once it appears, waiting up
# to $2 seconds (default 30). Empty output + non-zero exit = never appeared.
ui_wait_for_center() {
  local label="$1" timeout="${2:-30}" i center
  for ((i = 0; i < timeout; i++)); do
    if center="$(ui_center_of "$label" 2>/dev/null)" && [ -n "$center" ]; then
      printf '%s' "$center"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Waits up to $2 seconds for a node with the given label to appear.
ui_wait_for() {
  ui_wait_for_center "$1" "${2:-30}" >/dev/null
}

# Taps the node with the given label, waiting for it to appear first. Refuses to
# tap unless the app owns the focus — a stray foreground app would otherwise
# swallow the touch and the drive would silently go nowhere.
ui_tap() {
  local label="$1" timeout="${2:-30}" center
  center="$(ui_wait_for_center "$label" "$timeout")" || return 1
  if ! app_in_focus; then
    echo "error: refusing to tap '$label' — $PKG does not own the focus" >&2
    return 1
  fi
  # shellcheck disable=SC2086 # centre is intentional word-splitting into x y.
  "$ADB" -s "$SERIAL" shell input tap $center
}

# The app's package is installed and the process is alive.
app_is_running() {
  "$ADB" -s "$SERIAL" shell pidof "$PKG" >/dev/null 2>&1
}

# The app's window currently owns the input focus. Another app in the
# foreground would make every tap land somewhere else.
app_in_focus() {
  "$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null \
    | grep -m1 mCurrentFocus | grep -q "$PKG"
}

# Brings the app to the foreground and waits until it owns the focus. A stray
# foreground app (the emulator image ships extras) is force-stopped first: with
# it on top, taps would land on it and the drive would silently go nowhere.
bring_app_to_front() {
  local timeout="${1:-30}" i
  if app_in_focus; then
    return 0
  fi
  # Force-stop whatever unrelated window is on top.
  local top
  top="$("$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null \
    | grep -m1 mCurrentFocus | sed -n 's/.*u0 \([^/]*\)\/.*/\1/p' | tr -d '\r')"
  if [ -n "$top" ] && [ "$top" != "$PKG" ]; then
    "$ADB" -s "$SERIAL" shell am force-stop "$top" >/dev/null 2>&1 || true
  fi
  "$ADB" -s "$SERIAL" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
  for ((i = 0; i < timeout; i++)); do
    if app_in_focus; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Reads a device file inside the app's own data dir (debug builds are
# debuggable, so `run-as` works without root).
app_read_file() {
  "$ADB" -s "$SERIAL" shell "run-as $PKG cat '$1'" 2>/dev/null
}

# Prints one scalar field of the given JsonFileStore document on the device, or
# exits non-zero when the document is absent or the field is missing.
snapshot_field() {
  local raw
  raw="$(app_read_file "$1")"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | python3 -c '
import json, sys
field = sys.argv[1]
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict) or field not in doc:
    sys.exit(1)
value = doc[field]
# Reject containers and booleans: only scalars are useful to the shell, and
# `True` would otherwise read as the status "True".
if isinstance(value, bool) or not isinstance(value, (int, float, str)):
    sys.exit(1)
print(value)
' "$2"
}

# Prints the numeric `distance_m` of the given JsonFileStore document on the
# device, or exits non-zero when the document is absent or has no distance.
snapshot_distance_meters() {
  local raw
  raw="$(app_read_file "$1")"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = doc.get("distance_m")
if not isinstance(value, (int, float)):
    sys.exit(1)
print(value)
'
}

# Called once after boot; harmless to repeat per suite.
hide_system_dialogs

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

# Android's location-permission dialog cannot be answered from a test, so a
# background loop presses BACK to dismiss it. A dismissed dialog resolves the
# in-flight `requestPermission` as DENIED (never DENIED_FOREVER), which is
# exactly the state the `denied` case wants to observe.
start_dialog_dismisser() {
  (
    while true; do
      # Only press BACK when Android's permission dialog owns the foreground:
      # a blind BACK loop would also pop the app's own screens.
      # The dialog lives in the permission controller's own task, so the
      # focused window (not the resumed activity) is what names it.
      focus="$("$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null \
        | grep -m1 'mCurrentFocus' || true)"
      case "$focus" in
        *permissioncontroller*) "$ADB" -s "$SERIAL" shell input keyevent 4 >/dev/null 2>&1 || true ;;
      esac
      sleep 1
    done
  ) &
  DISMISS_PID=$!
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

run_map_smoke_suite() {
  # Fresh install so the map smoke cannot inherit a previous suite's saved
  # regions or routes.
  reset_app_state
  echo ">> Running the map smoke integration test on $SERIAL..."
  # MAP_VIEW=true is what makes the suite run at all (its skip gate); the real
  # map pulls the style document and tiles over the network.
  if ! ${TEST_TIMEOUT_CMD[@]+"${TEST_TIMEOUT_CMD[@]}"} flutter test \
    integration_test/map_smoke_test.dart -d "$SERIAL" \
    --dart-define=MAP_VIEW=true \
    ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}; then
    collect_artifacts map-smoke
    exit 1
  fi
}

# --- Permission mode: establish an explicit Android state per case ----------
#
# Android's own permission dialog cannot be answered from a test, so each case
# establishes the platform state and names it through
# --dart-define=PERMISSION_CASE; the test then asserts what the app does with
# that real answer. Android state is applied *after* `flutter test` has
# installed the package (a flag set on an absent package is a silent no-op, and
# `flutter test` installs on every invocation), via a watcher that fires once
# the package appears.

# Applies one case's Android state. Safe to call repeatedly — every command is
# idempotent and best-effort.
apply_permission_state() {
  case "$1" in
    denied)
      # Permission missing but still requestable. The dialog cannot be answered
      # from a test, so a BACK press dismisses it (started separately);
      # geolocator resolves the dismissed request as DENIED.
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" COARSE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" FINE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell cmd location set-location-enabled true >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell settings put secure location_mode 3 >/dev/null 2>&1 || true
      ;;
    deniedForever)
      # "Never ask again": revoke and mark the permission user-fixed, which is
      # what makes geolocator report DENIED_FOREVER and *not* show a dialog.
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm set-permission-flags "$PKG" android.permission.ACCESS_FINE_LOCATION user-fixed >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm set-permission-flags "$PKG" android.permission.ACCESS_COARSE_LOCATION user-fixed >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell cmd location set-location-enabled true >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell settings put secure location_mode 3 >/dev/null 2>&1 || true
      ;;
    servicesOff)
      # Permission granted, master switch off: the app must blame the services,
      # not the permission.
      "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" COARSE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" FINE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell cmd location set-location-enabled false >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell settings put secure location_mode 0 >/dev/null 2>&1 || true
      ;;
    grantedAfterDenial)
      # Denied first so the error screen appears, then granted asynchronously
      # once it is up (the watcher does that part) so RETRY can succeed.
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" COARSE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell appops set "$PKG" FINE_LOCATION allow >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell cmd location set-location-enabled true >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell settings put secure location_mode 3 >/dev/null 2>&1 || true
      ;;
  esac
}

# Applies a case's state in the background as soon as `flutter test` has
# installed the package. A 3 s settle lets the app open its gate first, so the
# app observes the state the case intends rather than a half-applied one.
#  * `grantedAfterDenial` additionally flips to granted ~12 s in, once the
#    refusal is on screen, so the test's RETRY loop exercises the recovery.
start_permission_watcher() {
  local case="$1"
  (
    until "$ADB" -s "$SERIAL" shell pm list packages 2>/dev/null | grep -q "$PKG"; do
      sleep 1
    done
    sleep 3
    apply_permission_state "$case"
    if [ "$case" = "grantedAfterDenial" ]; then
      sleep 12
      "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
    fi
  ) &
  WATCHER_PID=$!
}

run_permissions_suite() {
  local cases="denied deniedForever servicesOff grantedAfterDenial"
  local case
  for case in $cases; do
    echo ">> Permission case: $case"
    reset_app_state

    # The dialog cannot be answered from a test; press BACK only while the
    # permission controller owns the foreground (a blind BACK loop would also
    # pop the app's own screens).
    start_dialog_dismisser
    start_permission_watcher "$case"

    if ! ${TEST_TIMEOUT_CMD[@]+"${TEST_TIMEOUT_CMD[@]}"} flutter test integration_test/permissions_test.dart -d "$SERIAL" \
      --dart-define=USE_DEVICE_GPS=true \
      --dart-define=REQUIRE_DEVICE_GPS=true \
      --dart-define=PERMISSION_CASE="$case" \
      ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}; then
      echo ">> Permission case '$case' failed — dumping state:" >&2
      "$ADB" -s "$SERIAL" shell dumpsys package "$PKG" 2>/dev/null \
        | sed -n '/runtime permissions/,/^$/p' || true
      "$ADB" -s "$SERIAL" shell dumpsys location 2>/dev/null | sed -n '1,12p' || true
      stop_permission_helpers
      collect_artifacts "permissions-$case"
      exit 1
    fi

    stop_permission_helpers
  done
}

# Stops the per-case background helpers so the next case starts clean.
stop_permission_helpers() {
  if [ -n "$DISMISS_PID" ]; then
    kill "$DISMISS_PID" >/dev/null 2>&1 || true
    DISMISS_PID=""
  fi
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
    WATCHER_PID=""
  fi
  # Restore the master switch for the next case's precondition.
  "$ADB" -s "$SERIAL" shell cmd location set-location-enabled true >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell settings put secure location_mode 3 >/dev/null 2>&1 || true
}

# --- Process-death mode: genuine kill of the real app ------------------------
#
# `flutter test` installs a fresh test APK and *uninstalls it on exit*, so app
# storage cannot survive between two `flutter test` invocations (verified on the
# API-36 emulator: the package is gone and `run-as` answers "unknown package"
# immediately after the run, even when the process is force-stopped mid-test).
# `flutter run` behaves differently: it leaves the package installed, and a
# later run reinstalls in place (`install -r`), preserving the data directory.
#
# So the suite runs the production-shaped app through a test entry point,
# `integration_test/process_death_main.dart`, which is identical to
# `lib/main.dart` except that it turns Flutter's semantic tree on — without it
# uiautomator cannot see Flutter's widgets, so no tap could be aimed. The
# harness then:
#
#   1. `flutter run -t integration_test/process_death_main.dart` — install the
#      app once (no USE_DEVICE_GPS, so the deterministic demo timeline drives
#      the run and no permission is involved);
#   2. seed the settings document (intro and §33 rationale already seen) and a
#      one-route catalog, then drive Home with real taps: RACE YOUR BEST →
#      START, and wait until the interrupted-run snapshot reaches the real
#      on-disk JsonFileStore. The run has to be a *race*: the resumed run
#      belongs to the race flow (§28), while the new-route recording flow
#      (`RECORD ROUTE`) deliberately starts a fresh line every time — tapping
#      it after a relaunch would neither restore nor preserve the old run;
#   3. `am force-stop` — a real process kill, not a widget rebuild;
#   4. assert the snapshot file is still on disk with its distance and moving
#      time;
#   5. `am start` the same installed APK — a genuinely new process — open the
#      race flow and assert on the *snapshot*, not the animating live screen
#      (uiautomator waits for an idle window, so a dump there costs ~12 s and
#      sometimes fails): same `started_at`, status still running, distance and
#      moving time past where the kill left them, and no sealed activity in
#      `activities.json`.
#
# The app documents directory is *not* cleared at any point after the write.

# Writes one JsonFileStore document into the app's data dir before launch.
# The payload travels base64-encoded so the JSON's quotes never have to survive
# two shells; `run-as` needs the package installed and a debuggable build, and
# `app_flutter` is path_provider's documents dir.
seed_app_document() {
  local name="$1" json="$2" encoded
  encoded="$(printf '%s' "$json" | base64 | tr -d '\n')"
  "$ADB" -s "$SERIAL" shell \
    "run-as $PKG sh -c 'mkdir -p app_flutter && echo $encoded | base64 -d > app_flutter/$name.json'" \
    >/dev/null 2>&1
}

run_process_death_suite() {
  local snapshot_path="app_flutter/run_snapshot.json"
  local entry="integration_test/process_death_main.dart"

  # `flutter run` attaches and stays in the foreground; run it in the background
  # so the harness can drive the app over adb. It exits on its own when the app
  # process is killed in phase 2.
  reset_app_state
  echo ">> Process-death: building and installing the app (demo timeline)..."
  RUN_LOG="$ARTIFACTS_DIR/process-death-run.log"
  mkdir -p "$ARTIFACTS_DIR"
  flutter run -t "$entry" -d "$SERIAL" \
    ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"} > "$RUN_LOG" 2>&1 &
  local run_pid=$!
  # `flutter run` is left running across the kill/relaunch below; make sure it is
  # gone when the suite ends one way or another.
  PD_RUN_PID="$run_pid"

  # Wait for the install to land and the app to draw its first frame.
  local i
  for ((i = 0; i < 240; i++)); do
    if app_is_running; then
      break
    fi
    sleep 1
  done
  if ! app_is_running; then
    echo "error: the app never started under flutter run" >&2
    tail -20 "$RUN_LOG" >&2 || true
    collect_artifacts process-death-start
    exit 1
  fi

  # --- Open on Home with one route: seed the settings document (intro and the
  # §33 rationale already seen) plus a one-route catalog. Home only offers
  # RACE YOUR BEST when a route exists, and the race flow is the only flow
  # that restores an interrupted run (§28) — see the header note.
  if ! seed_app_document settings \
    '{"onboarding":true,"locationRationale":true}' ||
    ! seed_app_document routes \
    '[{"id":"process-death-loop","name":"Process Death Loop","distance_m":4760.0,"geometry":[{"lat":48.1371,"lon":11.5754},{"lat":48.1392,"lon":11.5789},{"lat":48.1410,"lon":11.5751},{"lat":48.1371,"lon":11.5754}],"attempt_count":0}]'; then
    echo "error: could not seed the app's documents" >&2
    collect_artifacts process-death-install
    exit 1
  fi
  # Restart so the seeded settings are read at launch.
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 1

  # --- Phase 1: record an interrupted run -----------------------------------
  echo ">> Process-death phase 1/3: record a run and leave the snapshot on disk..."
  # A stray foreground app would swallow every tap (verified: a leftover app
  # from the emulator image stole focus and the drive silently went nowhere).
  if ! bring_app_to_front 60; then
    echo "error: the app never came to the foreground" >&2
    collect_artifacts process-death-home
    exit 1
  fi
  if ! ui_wait_for 'RACE YOUR BEST' 90; then
    echo "error: the app's Home screen never appeared" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-home
    exit 1
  fi

  if ! ui_tap 'RACE YOUR BEST' 20; then
    echo "error: RACE YOUR BEST was not tappable" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-home
    exit 1
  fi
  # The race pre-run gates START on a fix (the demo timeline supplies one
  # without any permission); READY TO RUN proves the button is enabled.
  if ! ui_wait_for 'READY TO RUN' 90; then
    echo "error: the race pre-run never became ready" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-record
    exit 1
  fi
  if ! ui_tap 'START' 20; then
    echo "error: START was not tappable" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-record
    exit 1
  fi
  # The 3-2-1-GO countdown hands over to the live run, which persists a
  # snapshot every ~5 s. Assert on that snapshot, not on the live screen:
  # uiautomator waits for a settled window and the live screen animates
  # continuously, so a dump there costs ~12 s and sometimes fails to connect,
  # which made a UI gate unusable. The snapshot is what the relaunch restores,
  # so it is also the more direct thing to assert.
  local recorded_status="" recorded_distance="" recorded_started=""
  local recorded_moving="" recorded=0
  for ((i = 0; i < 120; i++)); do
    if recorded_status="$(snapshot_field "$snapshot_path" status)" &&
      [ "$recorded_status" = "running" ] &&
      recorded_distance="$(snapshot_distance_meters "$snapshot_path")" &&
      awk "BEGIN { exit !($recorded_distance > 0) }" &&
      recorded_started="$(snapshot_field "$snapshot_path" started_at)" &&
      recorded_moving="$(snapshot_field "$snapshot_path" moving_s)"; then
      recorded=1
      break
    fi
    sleep 1
  done
  if [ "$recorded" != "1" ]; then
    echo "error: no running, non-zero run_snapshot reached the device store" >&2
    echo ">> last snapshot read: $(app_read_file "$snapshot_path" | head -c 400)" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-write
    exit 1
  fi
  echo ">> snapshot on disk: started_at=$recorded_started distance_m=$recorded_distance moving_s=$recorded_moving"

  # --- Phase 2: a genuine process kill --------------------------------------
  echo ">> Process-death phase 2/3: force-stop the app process..."
  local pid_before
  pid_before="$("$ADB" -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  if [ -z "$pid_before" ]; then
    echo "error: the app process was not running before the kill" >&2
    collect_artifacts process-death-write
    exit 1
  fi
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 2
  if app_is_running; then
    echo "error: the app process survived am force-stop" >&2
    collect_artifacts process-death-kill
    exit 1
  fi
  echo ">> process $pid_before killed; verifying the snapshot survived..."

  # The kill must not have touched storage: read the file again and assert a
  # non-zero distance is still there (the observer may have ticked once more
  # before the kill, so assert "at least what we saw", not equality).
  local survived_distance="" survived_moving=""
  if ! survived_distance="$(snapshot_distance_meters "$snapshot_path")"; then
    echo "error: run_snapshot disappeared after the process kill" >&2
    collect_artifacts process-death-kill
    exit 1
  fi
  if ! survived_moving="$(snapshot_field "$snapshot_path" moving_s)"; then
    echo "error: the surviving run_snapshot has no moving_s" >&2
    collect_artifacts process-death-kill
    exit 1
  fi
  if ! awk "BEGIN { exit !($survived_distance > 0) }"; then
    echo "error: the snapshot lost its distance across the kill ($survived_distance)" >&2
    collect_artifacts process-death-kill
    exit 1
  fi
  echo ">> survived the kill: distance_m=$survived_distance moving_s=$survived_moving"

  # --- Phase 3: a fresh process restores the interrupted run ----------------
  echo ">> Process-death phase 3/3: relaunch and assert the run was restored..."
  # `am start` is the relaunch: a genuinely new process reading the same
  # documents directory. Focus is asserted before any tap.
  if ! bring_app_to_front 60; then
    echo "error: the relaunched app never came to the foreground" >&2
    collect_artifacts process-death-read
    exit 1
  fi
  # The fresh process comes up on the same Home screen; the interrupted race is
  # restored when the race flow opens (`RecordFlowScreen._openSession` resumes
  # the snapshot instead of starting a new session, §28). Resume is deliberately
  # not automatic on Home, so tap the same entry the user would.
  if ! ui_wait_for 'RACE YOUR BEST' 60; then
    echo "error: the relaunched process never reached Home" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-read
    exit 1
  fi
  if ! ui_tap 'RACE YOUR BEST' 20; then
    echo "error: RACE YOUR BEST was not tappable after relaunch" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-read
    exit 1
  fi

  # A zeroed distance, a fresh session or a sealed run would all be the silent
  # data loss this test exists to catch. Assert on the persisted snapshot
  # again (the live screen never idles, see phase 1): the resumed run keeps the
  # snapshot's `started_at`, keeps adding ground and moving time past where the
  # kill left it, and is *not* sealed as a completed activity.
  local restored_status="" restored_distance="" restored_started=""
  local restored_moving="" resumed=0
  for ((i = 0; i < 90; i++)); do
    if restored_status="$(snapshot_field "$snapshot_path" status)" &&
      [ "$restored_status" = "running" ] &&
      restored_started="$(snapshot_field "$snapshot_path" started_at)" &&
      [ "$restored_started" = "$recorded_started" ] &&
      restored_distance="$(snapshot_distance_meters "$snapshot_path")" &&
      restored_moving="$(snapshot_field "$snapshot_path" moving_s)" &&
      awk "BEGIN { exit !($restored_distance > $survived_distance) }" &&
      awk "BEGIN { exit !($restored_moving > $survived_moving) }"; then
      resumed=1
      break
    fi
    sleep 1
  done
  if [ "$resumed" != "1" ]; then
    echo "error: the relaunched process did not resume the interrupted run" >&2
    echo ">> before kill: started_at=$recorded_started distance_m=$recorded_distance moving_s=$recorded_moving" >&2
    echo ">> survived kill: distance_m=$survived_distance moving_s=$survived_moving" >&2
    echo ">> after relaunch: started_at=$restored_started status=$restored_status distance_m=$restored_distance moving_s=$restored_moving" >&2
    echo ">> snapshot now: $(app_read_file "$snapshot_path" | head -c 400)" >&2
    ui_dump >&2 || true
    collect_artifacts process-death-read
    exit 1
  fi
  echo ">> restored run: started_at=$restored_started distance_m=$restored_distance moving_s=$restored_moving"

  # A resumed run is still in progress: it must not have been sealed into the
  # activity history (that would be a completed run, not a recovered one).
  local activities=""
  if activities="$(app_read_file app_flutter/activities.json)" &&
    [ -n "$activities" ] && [ "$activities" != "[]" ]; then
    echo "error: the interrupted run was sealed as a completed activity: $(printf '%s' "$activities" | head -c 200)" >&2
    collect_artifacts process-death-read
    exit 1
  fi
  echo ">> recovery verified: the interrupted run is live in the new process."
}

run_demo_suite() {
  # `--smoke` (old-API PR jobs) keeps only the record-and-save journey; the
  # full suite also covers racing, the route library, and relaunch.
  local target="integration_test"
  if [ "$SMOKE" = "1" ]; then
    target="integration_test/app_test.dart"
  fi
  echo ">> Running integration tests ($target) on $SERIAL..."
  if ! ${TEST_TIMEOUT_CMD[@]+"${TEST_TIMEOUT_CMD[@]}"} flutter test "$target" -d "$SERIAL" \
    ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}; then
    collect_artifacts demo
    exit 1
  fi
}

cd "$(dirname "$0")/.."
if [ "$DEVICE_GPS" = "1" ]; then
  run_device_gps_suite
elif [ "$MAP_SMOKE" = "1" ]; then
  run_map_smoke_suite
elif [ "$PERMISSIONS" = "1" ]; then
  run_permissions_suite
elif [ "$PROCESS_DEATH" = "1" ]; then
  run_process_death_suite
else
  run_demo_suite
fi
