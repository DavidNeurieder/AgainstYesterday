#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

# Full test orchestration for "Against Yesterday".
#
# Runs the host-side Rust/Flutter checks and (unless QUICK=1) the on-device
# integration suite, aggregating results, timings and per-target logs.
#
# Usage (from repo root):
#   make full-test                      # everything locally available
#   make full-test QUICK=1               # skip emulator integration tests
#   make full-test PARALLEL=1            # run independent host checks together
#   make full-test KEEP_LOGS=1           # keep per-target logs (default in CI)
#   make ci-test                        # exactly the checks CI requires
#   make full-test-device               # force the on-device suite
#
# Environment:
#   QUICK=1          skip on-device integration tests
#   PARALLEL=1       run independent host checks concurrently
#   KEEP_LOGS=1      keep build/full-test/*.log (default: keep in CI)
#   CI=1             treat as CI (keep logs, no parallel by default)
#   TIMEOUT          per-target timeout in seconds (default 1800)
#   LOG_DIR          log directory (default build/full-test)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$REPO_ROOT/app"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/build/full-test}"
TIMEOUT="${TIMEOUT:-1800}"

QUICK="${QUICK:-0}"
PARALLEL="${PARALLEL:-0}"
KEEP_LOGS="${KEEP_LOGS:-0}"
CI="${CI:-0}"
DEVICE="${DEVICE:-0}"

if [ "$CI" = "1" ]; then KEEP_LOGS=1; fi

mkdir -p "$LOG_DIR"

# ---------- helpers ----------
red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

classify_exit() {
    # $1 = exit code
    case "$1" in
        0)   echo "PASS" ;;
        124) echo "TIMEOUT" ;;
        127) echo "MISSING" ;;
        130) echo "INTERRUPTED" ;;
        *)   echo "FAIL($1)" ;;
    esac
}

preflight() {
    local missing=""
    have cargo   || missing="$missing cargo"
    have rustc  || missing="$missing rustc"
    have flutter || missing="$missing flutter"
    if [ -n "$missing" ]; then
        echo "preflight: missing tools:$missing" >&2
        exit 2
    fi
    if [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
        echo "preflight: not in repo root ($REPO_ROOT)" >&2
        exit 2
    fi
    # Java 21 for Android builds (best-effort check).
    if [ -z "${JAVA_HOME:-}" ]; then
        for d in /usr/lib/jvm/*21* /opt/java/*21*; do
            if [ -x "$d/bin/javac" ]; then export JAVA_HOME="$d"; break; fi
        done
    fi
    if [ -n "${JAVA_HOME:-}" ] && [ ! -x "$JAVA_HOME/bin/javac" ]; then
        echo "preflight: JAVA_HOME set but javac not found" >&2
    fi
    echo "preflight: OK (JAVA_HOME=${JAVA_HOME:-unset})"
}

# Run a single target. Args: name command...
# Records timing, exit code, classification into arrays via globals.
run_target() {
    local name="$1"; shift
    local log="$LOG_DIR/$name.log"
    local start end dur rc status
    start=$(date +%s)
    echo "==> $name"
    if [ "$KEEP_LOGS" = "1" ]; then
        timeout "$TIMEOUT" "$@" >"$log" 2>&1
    else
        timeout "$TIMEOUT" "$@" >"$log" 2>&1
    fi
    rc=$?
    end=$(date +%s)
    dur=$((end - start))
    status=$(classify_exit "$rc")
    printf '   %-12s %6ss  (%s)\n' "$status" "$dur" "$name"
    # Append to summary file
    printf '%s|%s|%s|%s\n' "$name" "$status" "$dur" "$rc" >> "$LOG_DIR/summary.txt"
    if [ "$rc" -ne 0 ]; then
        FAILED_TARGETS="$FAILED_TARGETS $name"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        PASSED_COUNT=$((PASSED_COUNT + 1))
    fi
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    return 0
}

# ---------- target definitions ----------
# Each function runs one check in the correct working directory.

t_engine_fmt() {
    cd "$REPO_ROOT" && cargo fmt --all --check
}
t_engine_lint() {
    cd "$REPO_ROOT" && cargo clippy --all-targets --all-features -- -D warnings
}
t_engine_test() {
    cd "$REPO_ROOT" && cargo test --all-features
}
t_engine_doc() {
    cd "$REPO_ROOT" && cargo doc --no-deps
}
t_test_rust_engine() {
    cd "$APP_DIR" && flutter test --dart-define=REQUIRE_RUST_ENGINE=true
}
t_lint() {
    cd "$APP_DIR" && flutter analyze
}
t_tz_test() {
    cd "$APP_DIR" && TZ=Europe/Berlin flutter test test/route_library_test.dart
}
t_connected_engine() {
    cd "$APP_DIR" && ./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true
}

# ---------- main ----------
preflight

FAILED_TARGETS=""
PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT=0
: > "$LOG_DIR/summary.txt"

echo
echo "╔══════════════════════════════════════════╗"
echo "║       AGAINST YESTERDAY FULL TEST        ║"
echo "╚══════════════════════════════════════════╝"
echo "repo:   $REPO_ROOT"
echo "logs:   $LOG_DIR"
echo "quick:  $QUICK   parallel: $PARALLEL   device: $DEVICE"
echo

# Host-side checks.
HOST_TARGETS=(engine-fmt engine-lint engine-test engine-doc test-rust-engine lint tz-test)

run_host_target() {
    case "$1" in
        engine-fmt)       run_target "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo fmt --all --check' ;;
        engine-lint)      run_target "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo clippy --all-targets --all-features -- -D warnings' ;;
        engine-test)      run_target "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo test --all-features' ;;
        engine-doc)       run_target "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo doc --no-deps' ;;
        test-rust-engine) run_target "$1" bash -c 'cd "'"$APP_DIR"'" && flutter test --dart-define=REQUIRE_RUST_ENGINE=true' ;;
        lint)             run_target "$1" bash -c 'cd "'"$APP_DIR"'" && flutter analyze' ;;
        tz-test)          run_target "$1" bash -c 'cd "'"$APP_DIR"'" && TZ=Europe/Berlin flutter test test/route_library_test.dart' ;;
    esac
}

if [ "$PARALLEL" = "1" ]; then
    # Launch all host checks concurrently, each writing its own log and a
    # small status file. Aggregate once they finish.
    jobdir="$LOG_DIR/jobs"
    mkdir -p "$jobdir"
    rm -f "$jobdir"/*.status
    for t in "${HOST_TARGETS[@]}"; do
        (
            start=$(date +%s)
            case "$t" in
                engine-fmt)       bash -c 'cd "'"$REPO_ROOT"'" && cargo fmt --all --check' ;;
                engine-lint)      bash -c 'cd "'"$REPO_ROOT"'" && cargo clippy --all-targets --all-features -- -D warnings' ;;
                engine-test)      bash -c 'cd "'"$REPO_ROOT"'" && cargo test --all-features' ;;
                engine-doc)       bash -c 'cd "'"$REPO_ROOT"'" && cargo doc --no-deps' ;;
                test-rust-engine) bash -c 'cd "'"$APP_DIR"'" && flutter test --dart-define=REQUIRE_RUST_ENGINE=true' ;;
                lint)             bash -c 'cd "'"$APP_DIR"'" && flutter analyze' ;;
                tz-test)          bash -c 'cd "'"$APP_DIR"'" && TZ=Europe/Berlin flutter test test/route_library_test.dart' ;;
            esac
        ) >"$LOG_DIR/$t.log" 2>&1 &
        echo $! > "$jobdir/$t.pid"
    done
    for t in "${HOST_TARGETS[@]}"; do
        pid=$(cat "$jobdir/$t.pid")
        wait "$pid"
        rc=$?
        # append a synthetic timing of 0 since we did not capture per-job duration
        status=$(classify_exit "$rc")
        printf '%s|%s|%s|%s\n' "$t" "$status" "0" "$rc" >> "$LOG_DIR/summary.txt"
        if [ "$rc" -ne 0 ]; then
            FAILED_TARGETS="$FAILED_TARGETS $t"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        else
            PASSED_COUNT=$((PASSED_COUNT + 1))
        fi
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        printf '   %-12s  %s\n' "$status" "$t"
    done
else
    for t in "${HOST_TARGETS[@]}"; do
        run_host_target "$t"
    done
fi

# On-device integration suite.
RUN_DEVICE=0
if [ "$DEVICE" = "1" ]; then RUN_DEVICE=1; fi
if [ "$QUICK" = "0" ] && [ "$CI" != "1" ]; then
    # Only run if an emulator/device is available.
    if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "device$"; then
        RUN_DEVICE=1
    fi
fi

if [ "$RUN_DEVICE" = "1" ]; then
    run_target "connected-test-engine" bash -c 'cd "'"$APP_DIR"'" && ./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true'
else
    echo "==> connected-test-engine   SKIPPED (no device / QUICK=1 / CI)"
fi

# ---------- summary ----------
echo
echo "──────────────────────────────────────────────"
if [ "$PARALLEL" != "1" ]; then
    while IFS='|' read -r name status dur rc; do
        printf '  %-24s %-10s %6ss\n' "$name" "$status" "$dur"
    done < "$LOG_DIR/summary.txt"
fi
echo
echo "RESULT: $PASSED_COUNT passed, $FAILED_COUNT failed, $TOTAL_COUNT total"
if [ -n "$FAILED_TARGETS" ]; then
    echo "FAILED:$FAILED_TARGETS"
    echo "Logs: $LOG_DIR"
    exit 1
fi
echo "FULL TEST: everything passed"
if [ "$KEEP_LOGS" != "1" ] && [ "$CI" != "1" ]; then
    rm -rf "$LOG_DIR"
fi
