#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reusable helper to test (and compare) reproducible F-Droid/unsigned builds.
#
# It can:
#   - build once or twice with a fixed SOURCE_DATE_EPOCH and record SHA-256s
#   - compare produced APK(s) against a reference APK/dir/hash file
#   - show a diffoscope report when diffoscope is installed
#
# The script is generic: point it at your app's build command and artifact(s).
#
# Examples:
#   # Local self-reproducibility check (build twice, compare):
#   ./app/tool/fdroid_repro.sh \
#     --build-cmd "cd app && flutter build apk --release --split-per-abi --target-platform android-arm64" \
#     --artifacts "app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" \
#     --clean-cmd "rm -rf app/build" \
#     --twice
#
#   # Compare a local build against reference APK(s) from F-Droid:
#   ./app/tool/fdroid_repro.sh \
#     --build-cmd "..." --artifacts "app/build/.../*.apk" \
#     --reference /path/to/fdroid-apks/
#
# Environment:
#   SOURCE_DATE_EPOCH  If unset, defaults to the HEAD commit timestamp.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fdroid_repro.sh [options]

Required:
  --build-cmd CMD         Shell command that produces the artifact(s).
  --artifacts GLOB        Glob/path to produced artifact(s) (quoted).

Optional:
  --clean-cmd CMD         Command run before each build (e.g. clean outputs).
  --twice                 Build twice and compare build 1 vs build 2.
  --reference PATH        Reference APK file, directory of APKs, or .sha256 file
                          to compare the produced artifact(s) against.
  --workdir DIR           Directory to store copies/hashes (default: ./build/repro-check).
  --epoch EPOCH           SOURCE_DATE_EPOCH override (default: git HEAD timestamp).
  -h, --help              Show this help.

Notes:
  - For a meaningful F-Droid comparison, run this inside the same build
    environment/toolchain as the F-Droid recipe (e.g. fdroidserver/buildserver),
    with the same commit, ABI targets, and prebuild steps.
  - APK signatures differ between builders; compare unsigned APK contents or use
    tools like apksigcopier/diffoscope for deeper analysis.
EOF
}

BUILD_CMD=""
ARTIFACTS=""
CLEAN_CMD=""
TWICE=0
REFERENCE=""
WORKDIR="build/repro-check"
EPOCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build-cmd) BUILD_CMD="${2:-}"; shift 2 ;;
    --artifacts) ARTIFACTS="${2:-}"; shift 2 ;;
    --clean-cmd) CLEAN_CMD="${2:-}"; shift 2 ;;
    --twice) TWICE=1; shift ;;
    --reference) REFERENCE="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --epoch) EPOCH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$BUILD_CMD" ] || [ -z "$ARTIFACTS" ]; then
  echo "error: --build-cmd and --artifacts are required" >&2
  usage >&2
  exit 2
fi

if [ -z "$EPOCH" ]; then
  EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"
fi
export SOURCE_DATE_EPOCH="$EPOCH"

echo "== F-Droid reproducibility check =="
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
echo "workdir=$WORKDIR"
mkdir -p "$WORKDIR"

collect() {
  local dest="$1"
  mkdir -p "$dest"
  # shellcheck disable=SC2086
  local files=( $ARTIFACTS )
  if [ ${#files[@]} -eq 0 ]; then
    echo "error: no artifacts matched: $ARTIFACTS" >&2
    exit 1
  fi
  local f
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      echo "error: artifact not found: $f" >&2
      exit 1
    fi
    cp "$f" "$dest/"
  done
  (cd "$dest" && sha256sum *.apk 2>/dev/null || sha256sum * ) | tee "$dest/SHA256SUMS"
}

run_build() {
  local label="$1"
  echo
  echo "== Build: $label =="
  if [ -n "$CLEAN_CMD" ]; then
    echo "+ $CLEAN_CMD"
    bash -lc "$CLEAN_CMD"
  fi
  echo "+ $BUILD_CMD"
  bash -lc "$BUILD_CMD"
  collect "$WORKDIR/$label"
}

compare_dirs() {
  local a="$1" b="$2"
  echo
  echo "== Compare: $a vs $b =="
  local rc=0
  # Compare common filenames by hash.
  local f name
  for f in "$a"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "SHA256SUMS" ] && continue
    if [ ! -f "$b/$name" ]; then
      echo "MISSING in $b: $name"
      rc=1
      continue
    fi
    local ha hb
    ha="$(sha256sum "$f" | awk '{print $1}')"
    hb="$(sha256sum "$b/$name" | awk '{print $1}')"
    if [ "$ha" = "$hb" ]; then
      echo "OK   $name  $ha"
    else
      echo "DIFF $name"
      echo "  $a: $ha"
      echo "  $b: $hb"
      if command -v diffoscope >/dev/null 2>&1; then
        echo "  -> diffoscope report: $WORKDIR/diffoscope-$name.html"
        diffoscope "$b/$name" "$f" --html "$WORKDIR/diffoscope-$name.html" || true
      else
        echo "  (install diffoscope for a detailed report)"
      fi
      rc=1
    fi
  done
  return "$rc"
}

compare_reference() {
  local ref="$1"
  echo
  echo "== Compare against reference: $ref =="
  if [ -f "$ref" ] && [[ "$ref" == *.sha256* || "$ref" == *SUMS* ]]; then
    echo "Reference is a checksum file; verifying produced artifacts against it:"
    (cd "$WORKDIR/build1" && sha256sum -c "$(realpath "$ref")")
    return $?
  fi
  local refdir="$WORKDIR/reference"
  rm -rf "$refdir"; mkdir -p "$refdir"
  if [ -d "$ref" ]; then
    cp "$ref"/*.apk "$refdir"/ 2>/dev/null || cp "$ref"/* "$refdir"/
    (cd "$refdir" && sha256sum * > SHA256SUMS) || true
  elif [ -f "$ref" ]; then
    cp "$ref" "$refdir/"
    (cd "$refdir" && sha256sum * > SHA256SUMS)
  else
    echo "error: reference not found: $ref" >&2
    exit 1
  fi
  compare_dirs "$WORKDIR/build1" "$refdir"
}

run_build "build1"

if [ "$TWICE" -eq 1 ]; then
  run_build "build2"
  if compare_dirs "$WORKDIR/build1" "$WORKDIR/build2"; then
    echo
    echo "RESULT: locally reproducible (build1 == build2)"
  else
    echo
    echo "RESULT: NOT locally reproducible (build1 != build2)" >&2
    exit 1
  fi
fi

if [ -n "$REFERENCE" ]; then
  if compare_reference "$REFERENCE"; then
    echo
    echo "RESULT: matches reference"
  else
    echo
    echo "RESULT: differs from reference" >&2
    exit 1
  fi
fi

echo
echo "Hashes recorded under: $WORKDIR/build1/SHA256SUMS"
