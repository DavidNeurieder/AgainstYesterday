# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

# Flutter commands run in app/; Cargo commands use the workspace at the repo
# root. The Rust FFI suites (test-rust-engine) need the host cdylib, and the
# on-device tests against the real engine (connected-test-engine) need the
# Android cdylibs installed under app/android/app/src/main/jniLibs — which
# engine-android produces and both connected-test-engine and full-test build
# for you.

.PHONY: build build-release install run test test-rust-engine lint tz-test \
        connected-test connected-test-engine engine-build engine-test \
        engine-lint engine-fmt engine-doc engine-android full-test clean

build:
	cd app && flutter build apk --debug

build-release:
	cd app && flutter build apk --release

run:
	cd app && flutter run

# Builds the debug APK and sideloads it into the connected device/emulator.
# The debug build ships the deterministic fake engine by default.
install: build
	adb install -r app/build/app/outputs/flutter-apk/app-debug.apk

test:
	cd app && flutter test

test-rust-engine: engine-build
	cd app && flutter test --dart-define=REQUIRE_RUST_ENGINE=true

lint:
	cd app && flutter analyze

# Re-runs the date-label assertions under a DST timezone, where consecutive
# local midnights are 23 hours apart (see CHANGELOG, Unreleased).
tz-test:
	cd app && TZ=Europe/Berlin flutter test test/route_library_test.dart

connected-test:
	cd app && ./tool/android_integration_test.sh

connected-test-engine: engine-android
	cd app && ./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true

engine-build:
	cargo build --release -p gps-engine

engine-test:
	cargo test --all-features

engine-lint:
	cargo clippy --all-targets --all-features -- -D warnings

engine-fmt:
	cargo fmt --all --check

engine-doc:
	cargo doc --no-deps

engine-android:
	./app/tool/build_rust_engine_android.sh

full-test: engine-fmt engine-lint engine-test engine-doc test-rust-engine \
           lint tz-test connected-test-engine

clean:
	cd app && flutter clean
	cargo clean