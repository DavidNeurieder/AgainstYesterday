#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# F-Droid pre-build cleanup for MapLibre.
#
# MapLibre's upstream Android build still ships Google Play Services
# location declarations and a GMS-specific implementation even though
# `maplibre_gl.playServicesLocation=false` is set in gradle.properties. Run
# this *after* `flutter pub get` and *before* F-Droid's source scan so the
# proprietary classes never reach the build.
set -euo pipefail

VERSION="${1:-0.27.1}"
MAPLIBRE_ANDROID="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/maplibre_gl-${VERSION}/android"

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