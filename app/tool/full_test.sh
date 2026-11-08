#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

# Full test orchestration for "Against Yesterday".
#
# Usage (from repo root):
#   make full-test                      # everything locally available
#   make full-test QUICK=1              # skip on-device integration tests
#   make full-test PARALLEL=1           # run independent host checks together
#   make full-test KEEP_LOGS=1          # keep per-target logs
#   make full-test DEVICE=1             # require and run on-device tests
#   make ci-test                        # exactly the checks CI requires
#   make full-test-device              # force the on-device suite
#
# Environment:
#   QUICK=1          skip on-device integration tests
#   PARALLEL=1       run independent host checks concurrently
#   KEEP_LOGS=1      keep build/full-test/*.log (default in CI)
#   CI=1             CI profile: no device tests, keep logs
#   DEVICE=1         require and run on-device tests (fail if unavailable)
#   TIMEOUT          per-target timeout in seconds (default 1800)
#   LOG_DIR          log directory (default build/full-test)
set -Eeuo pipefail

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

# ---------- config validation ----------
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: invalid TIMEOUT '$TIMEOUT' (expected positive integer)" >&2
    exit 2
fi
for v in QUICK PARALLEL KEEP_LOGS CI DEVICE; do
    val="${!v}"
    if [ "$val" != "0" ] && [ "$val" != "1" ]; then
        echo "error: $v must be 0 or 1 (got '$val')" >&2
        exit 2
    fi
done

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.status "$LOG_DIR"/*.log

CHILD_PIDS=()
cleanup() {
    for pid in "${CHILD_PIDS[@]}"; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap 'echo; echo "full-test interrupted"; cleanup; exit 130' INT
trap 'echo; echo "full-test terminated"; cleanup; exit 143' TERM
trap 'cleanup' EXIT

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

classify_exit() {
    case "$1" in
        0)   echo "PASS" ;;
        124) echo "TIMEOUT" ;;
        127) echo "MISSING" ;;
        130) echo "INTERRUPTED" ;;
        137) echo "KILLED" ;;
        *)   echo "FAIL" ;;
    esac
}

preflight() {
    local missing=""
    have cargo   || missing="$missing cargo"
    have rustc  || missing="$missing rustc"
    have flutter || missing="$missing flutter"
    have timeout || missing="$missing timeout"
    if [ -n "$missing" ]; then
        echo "preflight: missing tools:$missing" >&2
        exit 2
    fi
    if [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
        echo "preflight: not in repo root ($REPO_ROOT)" >&2
        exit 2
    fi
    if [ -z "${JAVA_HOME:-}" ]; then
        for d in /usr/lib/jvm/*21* /opt/java/*21*; do
            if [ -x "$d/bin/javac" ]; then export JAVA_HOME="$d"; break; fi
        done
    fi
    echo "preflight: OK (JAVA_HOME=${JAVA_HOME:-unset})"
}

# Run a single target. Args: name cmd...
# Writes "$LOG_DIR/$name.status" = "name|status|dur|rc" and a log file.
run_one() {
    local name="$1"; shift
    local log="$LOG_DIR/$name.log"
    local start end dur rc status
    start=$(date +%s%N)
    set +e
    timeout "$TIMEOUT" "$@" >"$log" 2>&1
    rc=$?
    set -e
    end=$(date +%s%N)
    dur=$(awk -v ns="$((end - start))" 'BEGIN { printf "%.1f", ns/1000000000 }')
    status=$(classify_exit "$rc")
    printf '%s|%s|%s|%s\n' "$name" "$status" "$dur" "$rc" > "$LOG_DIR/$name.status"
    printf '   %-12s %6ss  %s\n' "$status" "$dur" "$name"
}

skip_target() {
    local name="$1" reason="$2"
    printf '%s|%s|%s|%s\n' "$name" "SKIP" "0.0" "0" > "$LOG_DIR/$name.status"
    printf '   %-12s        %s  (%s)\n' "SKIP" "$name" "$reason"
}

# ---------- preflight ----------
preflight

echo
echo "╔══════════════════════════════════════════╗"
echo "║       AGAINST YESTERDAY FULL TEST        ║"
echo "╚══════════════════════════════════════════╝"
echo "repo:   $REPO_ROOT"
echo "logs:   $LOG_DIR"
echo "quick:  $QUICK   parallel: $PARALLEL   device: $DEVICE   ci: $CI"
echo

# ---------- host-side checks ----------
HOST_TARGETS=(engine-fmt engine-lint engine-test engine-doc test-rust-engine lint tz-test)

run_host_target() {
    case "$1" in
        engine-fmt)       run_one "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo fmt --all --check' ;;
        engine-lint)      run_one "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo clippy --all-targets --all-features -- -D warnings' ;;
        engine-test)      run_one "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo test --all-features' ;;
        engine-doc)       run_one "$1" bash -c 'cd "'"$REPO_ROOT"'" && cargo doc --no-deps' ;;
        test-rust-engine) run_one "$1" bash -c 'cd "'"$APP_DIR"'" && flutter test --dart-define=REQUIRE_RUST_ENGINE=true' ;;
        lint)             run_one "$1" bash -c 'cd "'"$APP_DIR"'" && flutter analyze' ;;
        tz-test)          run_one "$1" bash -c 'cd "'"$APP_DIR"'" && TZ=Europe/Berlin flutter test test/route_library_test.dart' ;;
    esac
}

if [ "$PARALLEL" = "1" ]; then
    export -f run_one classify_exit
    for t in "${HOST_TARGETS[@]}"; do
        (
            case "$t" in
                engine-fmt)       run_one "$t" bash -c 'cd "'"$REPO_ROOT"'" && cargo fmt --all --check' ;;
                engine-lint)      run_one "$t" bash -c 'cd "'"$REPO_ROOT"'" && cargo clippy --all-targets --all-features -- -D warnings' ;;
                engine-test)      run_one "$t" bash -c 'cd "'"$REPO_ROOT"'" && cargo test --all-features' ;;
                engine-doc)       run_one "$t" bash -c 'cd "'"$REPO_ROOT"'" && cargo doc --no-deps' ;;
                test-rust-engine) run_one "$t" bash -c 'cd "'"$APP_DIR"'" && flutter test --dart-define=REQUIRE_RUST_ENGINE=true' ;;
                lint)             run_one "$t" bash -c 'cd "'"$APP_DIR"'" && flutter analyze' ;;
                tz-test)          run_one "$t" bash -c 'cd "'"$APP_DIR"'" && TZ=Europe/Berlin flutter test test/route_library_test.dart' ;;
            esac
        ) &
        CHILD_PIDS+=($!)
    done
    wait
else
    for t in "${HOST_TARGETS[@]}"; do
        run_host_target "$t"
    done
fi


# ---------- device test selection ----------
RUN_DEVICE=0
if [ "$QUICK" = "1" ]; then
    RUN_DEVICE=0
elif [ "$DEVICE" = "1" ]; then
    RUN_DEVICE=1
elif [ "$CI" = "1" ]; then
    RUN_DEVICE=0
else
    if have adb && adb devices 2>/dev/null | grep -q "device$"; then
        RUN_DEVICE=1
    else
        RUN_DEVICE=0
    fi
fi

if [ "$DEVICE" = "1" ] && [ "$RUN_DEVICE" = "0" ]; then
    echo "error: DEVICE=1 but no adb device available" >&2
    exit 2
fi

if [ "$RUN_DEVICE" = "1" ]; then
    run_one "connected-test-engine" bash -c 'cd "'"$APP_DIR"'" && ./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true'
else
    skip_target "connected-test-engine" "no device / QUICK=1 / CI"
fi

# ---------- aggregate from status files ----------
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
TOTAL_COUNT=0
FAILED_TARGETS=""
for f in "$LOG_DIR"/*.status; do
    [ -e "$f" ] || continue
    IFS='|' read -r name status dur rc < "$f"
    case "$status" in
        PASS) PASSED_COUNT=$((PASSED_COUNT + 1)) ;;
        SKIP) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
        *)    FAILED_COUNT=$((FAILED_COUNT + 1)); FAILED_TARGETS="$FAILED_TARGETS $name" ;;
    esac
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
done

# ---------- summary ----------
echo
echo "──────────────────────────────────────────────"
for f in "$LOG_DIR"/*.status; do
    [ -e "$f" ] || continue
    IFS='|' read -r name status dur rc < "$f"
    printf '  %-24s %-10s %6ss\n' "$name" "$status" "$dur"
done
echo
echo "RESULT: $PASSED_COUNT passed, $FAILED_COUNT failed, $SKIPPED_COUNT skipped, $TOTAL_COUNT total"
if [ -n "$FAILED_TARGETS" ]; then
    echo "FAILED:$FAILED_TARGETS"
    echo "Logs: $LOG_DIR"
fi

# JUnit XML
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuite name="against-yesterday-full-test" tests="'"$TOTAL_COUNT"'" failures="'"$FAILED_COUNT"'" skipped="'"$SKIPPED_COUNT"'">'
    for f in "$LOG_DIR"/*.status; do
        [ -e "$f" ] || continue
        IFS='|' read -r name status dur rc < "$f"
        printf '  <testcase name="%s" time="%s">' "$name" "$dur"
        case "$status" in
            PASS) printf '</testcase>\n' ;;
            SKIP) printf '<skipped/></testcase>\n' ;;
            *)    printf '<failure message="%s"/></testcase>\n' "$status" ;;
        esac
    done
    echo '</testsuite>'
} > "$LOG_DIR/junit.xml"

if [ -n "$FAILED_TARGETS" ]; then
    exit 1
fi
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo "FULL TEST: PASSED WITH SKIPS"
else
    echo "FULL TEST: everything passed"
fi
if [ "$KEEP_LOGS" != "1" ] && [ "$CI" != "1" ]; then
    rm -rf "$LOG_DIR"
fi
