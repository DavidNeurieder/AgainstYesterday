#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

# Self-tests for app/tool/full_test.sh using fake executables.
# Run: bash app/tool/full_test_test.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FULL_TEST="$SCRIPT_DIR/full_test.sh"

pass=0
fail=0
assert() {
    # assert <description> <expected-substring> <actual-text>
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (expected '$needle')"
        fail=$((fail + 1))
    fi
}

make_fake_repo() {
    # $1 = temp root; creates minimal repo + fake bin dir on stdout
    local root="$1"
    mkdir -p "$root/repo/app/tool" "$root/bin"
    cp "$FULL_TEST" "$root/repo/app/tool/full_test.sh"
    chmod +x "$root/repo/app/tool/full_test.sh"
    # minimal Cargo.toml so preflight passes
    printf '[workspace]\nresolver = "2"\nmembers = ["rust/gps-engine"]\n' > "$root/repo/Cargo.toml"
    mkdir -p "$root/repo/rust/gps-engine"
    printf '[package]\nname="gps-engine"\nversion="0.1.0"\nedition="2024"\n' > "$root/repo/rust/gps-engine/Cargo.toml"
    # fake cargo & flutter
    cat > "$root/bin/cargo" << 'EOF'
#!/usr/bin/env bash
# succeed unless CARGO_FAIL is set
if [ "${CARGO_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
EOF
    cat > "$root/bin/flutter" << 'EOF'
#!/usr/bin/env bash
if [ "${FLUTTER_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
EOF
    cat > "$root/bin/timeout" << 'EOF'
#!/usr/bin/env bash
# pass-through timeout
shift 1
"$@"
EOF
    chmod +x "$root/bin/cargo" "$root/bin/flutter" "$root/bin/timeout"
    echo "$root"
}

echo "=== full_test self-tests ==="

# Test 1: all pass
tmp=$(mktemp -d)
make_fake_repo "$tmp" >/dev/null
out=$(PATH="$tmp/bin:$PATH" QUICK=1 KEEP_LOGS=1 bash "$tmp/repo/app/tool/full_test.sh" 2>&1) || true
assert "all-pass reports passed with skips" "PASSED WITH SKIPS" "$out"
assert "all-pass has 0 failed" "0 failed" "$out"
rm -rf "$tmp"

# Test 2: a failing target doesn't stop subsequent ones
tmp=$(mktemp -d)
make_fake_repo "$tmp" >/dev/null
out=$(PATH="$tmp/bin:$PATH" QUICK=1 KEEP_LOGS=1 CARGO_FAIL=1 bash "$tmp/repo/app/tool/full_test.sh" 2>&1) || true
assert "failure still runs later targets" "lint" "$out"
assert "failure reported" "FAILED:" "$out"
rm -rf "$tmp"

# Test 3: QUICK skips device tests
tmp=$(mktemp -d)
make_fake_repo "$tmp" >/dev/null
out=$(PATH="$tmp/bin:$PATH" QUICK=1 KEEP_LOGS=1 bash "$tmp/repo/app/tool/full_test.sh" 2>&1) || true
assert "quick skips device" "SKIP" "$out"
assert "quick says passed with skips" "PASSED WITH SKIPS" "$out"
rm -rf "$tmp"

# Test 4: invalid TIMEOUT rejected
tmp=$(mktemp -d)
make_fake_repo "$tmp" >/dev/null
out=$(PATH="$tmp/bin:$PATH" TIMEOUT=abc QUICK=1 bash "$tmp/repo/app/tool/full_test.sh" 2>&1) || true
assert "invalid timeout rejected" "invalid TIMEOUT" "$out"
rm -rf "$tmp"

# Test 5: JUnit XML produced
tmp=$(mktemp -d)
make_fake_repo "$tmp" >/dev/null
PATH="$tmp/bin:$PATH" QUICK=1 KEEP_LOGS=1 bash "$tmp/repo/app/tool/full_test.sh" >/dev/null 2>&1 || true
if [ -f "$tmp/repo/build/full-test/junit.xml" ]; then
    echo "  PASS: junit.xml produced"
    pass=$((pass + 1))
else
    echo "  FAIL: junit.xml missing"
    fail=$((fail + 1))
fi
rm -rf "$tmp"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
