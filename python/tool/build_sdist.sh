#!/usr/bin/env bash
# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a source distribution that can be installed without this repository.
# `gps-engine` is a path dependency outside python/, so a plain `maturin sdist`
# would not contain the Rust sources.  Stage a self-contained tree first:
#
#   python/            -> staging root
#   rust/gps-engine/   -> staging root/vendor/gps-engine
#
# The staged Cargo.toml is rewritten to point at the vendored copy, then maturin
# builds the sdist from that tree. Nothing in the checkout is modified.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python_dir="$(cd -- "$script_dir/.." && pwd)"
repo_root="$(cd -- "$python_dir/.." && pwd)"

out_dir="$python_dir/target/sdist"
maturin="${MATURIN:-$python_dir/.venv/bin/maturin}"

usage() {
    cat <<'EOF'
Usage: python/tool/build_sdist.sh [--out DIR] [--maturin PATH]

Builds a self-contained sdist in python/target/sdist by default. MATURIN may
also be set in the environment.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)
            [ "$#" -ge 2 ] || { echo "missing value for --out" >&2; exit 2; }
            out_dir="$2"
            shift 2
            ;;
        --maturin)
            [ "$#" -ge 2 ] || { echo "missing value for --maturin" >&2; exit 2; }
            maturin="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -x "$maturin" ] && ! command -v "$maturin" >/dev/null 2>&1; then
    echo "maturin not found at '$maturin'; set MATURIN or pass --maturin" >&2
    exit 2
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/ay-sdist.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

tar -C "$python_dir" \
    --exclude=.venv \
    --exclude=target \
    --exclude=dist \
    --exclude=build \
    --exclude=.pytest_cache \
    --exclude=__pycache__ \
    --exclude='*.pyc' \
    -cf - . | tar -C "$stage" -xf -

mkdir -p "$stage/vendor/gps-engine"
tar -C "$repo_root/rust/gps-engine" --exclude=target -cf - . \
    | tar -C "$stage/vendor/gps-engine" -xf -

# gps-engine inherits package fields from the root workspace. Inline them in
# the vendored copy so the sdist is a standalone Cargo package.
toml_value() {
    sed -n "s/^$1 = \"\\([^\"]*\\)\".*/\\1/p" "$repo_root/Cargo.toml" | head -n 1
}
engine_version="$(toml_value version)"
engine_edition="$(toml_value edition)"
engine_rust_version="$(toml_value rust-version)"
engine_license="$(toml_value license)"
engine_repository="$(toml_value repository)"
engine_manifest="$stage/vendor/gps-engine/Cargo.toml"
sed -i.bak \
    -e "s/^version.workspace = true/version = \"$engine_version\"/" \
    -e "s/^edition.workspace = true/edition = \"$engine_edition\"/" \
    -e "s/^rust-version.workspace = true/rust-version = \"$engine_rust_version\"/" \
    -e "s/^license.workspace = true/license = \"$engine_license\"/" \
    -e "s/^repository.workspace = true/repository = \"$engine_repository\"/" \
    "$engine_manifest"
rm -f "$engine_manifest.bak"

# pyproject.toml uses a license text; ship the repository license and toolchain
# pin so source archives carry the canonical files.
cp "$repo_root/LICENSE" "$stage/LICENSE"
if [ -f "$repo_root/rust-toolchain.toml" ]; then
    cp "$repo_root/rust-toolchain.toml" "$stage/rust-toolchain.toml"
fi

sed -i.bak 's#path = "../rust/gps-engine"#path = "vendor/gps-engine"#' "$stage/Cargo.toml"
rm -f "$stage/Cargo.toml.bak"

mkdir -p "$out_dir"
out_abs="$(cd -- "$out_dir" && pwd)"
(
    cd "$stage"
    "$maturin" sdist --out "$out_abs"
)

echo "sdist written to $out_abs"
