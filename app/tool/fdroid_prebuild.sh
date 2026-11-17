#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reproducibility cleanup for cached Flutter plugin sources.
#
# MapLibre's upstream Android build still ships Google Play Services
# location declarations and a GMS-specific implementation even though
# `maplibre_gl.playServicesLocation=false` is set in gradle.properties. Run
# this *after* `flutter pub get` and *before* F-Droid's source scan so the
# proprietary classes never reach the build.
#
# package:jni's Android CMake build also injects a GNU build ID that depends on
# the build directory, making libdartjni.so differ between local and F-Droid
# builds. Disable it in the cached source; the flag is deterministic and does
# not change runtime behaviour.
set -euo pipefail

PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
VERSION="${1:-0.27.1}"
MAPLIBRE_ANDROID="${PUB_CACHE_DIR}/hosted/pub.dev/maplibre_gl-${VERSION}/android"

test -f "${MAPLIBRE_ANDROID}/build.gradle"

# Drop the Play Services dependency lines.
sed -i -e '/com\.google\.android\.gms/d' "${MAPLIBRE_ANDROID}/build.gradle"

# Remove the GMS-specific implementation file.
rm -f "${MAPLIBRE_ANDROID}/src/main/java/org/maplibre/maplibregl/GMSLocationEngine.java"

# Patch LocationEngineFactory to stop referencing GMS.
FACTORY="${MAPLIBRE_ANDROID}/src/main/java/org/maplibre/maplibregl/LocationEngineFactory.kt"
if [ -f "${FACTORY}" ]; then
  python3 - "${FACTORY}" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Remove GMS imports.
s = s.replace("import com.google.android.gms.common.ConnectionResult\n", "")
s = s.replace("import com.google.android.gms.common.GoogleApiAvailability\n", "")
# Replace getLocationEngine body to avoid GMSLocationEngine reference.
s = re.sub(
    r"fun getLocationEngine\(context: Context\): LocationEngine \{\n(?:.*\n)*?    \}",
    "fun getLocationEngine(context: Context): LocationEngine {\n        return getDefaultLocationEngine(context)\n    }",
    s,
    count=1,
)
# Remove isGooglePlayServicesAvailable method.
s = re.sub(
    r"    private fun isGooglePlayServicesAvailable\(context: Context\): Boolean \{\n(?:.*\n)*?    \}\n",
    "",
    s,
    count=1,
)
open(p, "w").write(s)
PY
fi

# package:jni builds libdartjni.so with CMake. Its default GNU build ID depends
# on the linker invocation (and therefore on the absolute build path), which
# otherwise is the only remaining non-deterministic byte range in the APK.
JNI_CMAKE="${PUB_CACHE_DIR}/hosted/pub.dev/jni-1.1.0/src/CMakeLists.txt"
test -f "${JNI_CMAKE}"
python3 - "${JNI_CMAKE}" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'target_link_options(jni PRIVATE "-Wl,-z,max-page-size=16384")'
new = 'target_link_options(jni PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--build-id=none")'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit(f"unexpected jni CMakeLists.txt at {p}")
open(p, "w").write(s)
PY
