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

# Remove the GMS-specific source tree if present.
rm -rf "${MAPLIBRE_ANDROID}/src/gms"