# Copyright (C) 2026 David Neurieder
# SPDX-License-Identifier: AGPL-3.0-or-later

# Flutter commands run in app/; Cargo commands use the workspace at the repo
# root. Release APKs go through app/tool/repro_build.sh, which builds from a
# fixed source path so local and F-Droid artifacts are byte-identical.
# FLUTTER_BIN selects the Flutter executable (defaults to `flutter` on PATH).
# The Rust FFI suites (test-rust-engine) need the host cdylib. The app
# auto-selects the real engine when its native library is present, so
# engine-android (the Android cdylibs under app/android/app/src/main/jniLibs)
# is a prerequisite of the targets that produce a device artifact:
# build-release and install.
#
# Device artifacts record the live run from the phone's real GPS and render
# with the MapLibre map (which is what makes offline region downloads
# available). Both are the app's build defaults now: a bare `flutter build`
# already produces that artifact, and `USE_DEVICE_GPS=false`/`MAP_VIEW=false`
# are the opt-outs back to the deterministic demo timeline and the painter.
# The targets below restate the defaults so the build log says what was built;
# the hermetic on-device E2E passes the opt-outs explicitly.

# MapLibre (via maplibre_gl) compiles with Java 21, so the Android Gradle build
# must run on JDK 21 even though the app itself targets Java 17. Prefer an
# explicit JAVA_HOME; otherwise use the first JDK 21 on the machine.
JAVA21 ?= $(shell for d in /usr/lib/jvm/*21* /opt/java/*21*; do \
	if [ -x "$$d/bin/javac" ]; then echo "$$d"; break; fi; done)
ifndef JAVA_HOME
ifneq ($(JAVA21),)
export JAVA_HOME := $(JAVA21)
endif
endif

.PHONY: build build-release install run run-linux run-cli test test-rust-engine lint tz-test \
        connected-test connected-test-engine connected-test-gps \
        engine-build engine-test engine-lint engine-fmt engine-doc \
        engine-android maplibre-fdroid-clean full-test full-test-device ci-test check check-versions clean \
        build-linux-release build-cli-release release-all repro-check repro-compare \
        stale-android-apks-debug stale-android-apks-release stale-android-jnilibs \
        python-venv python-develop python-build python-test python-clean

# Android artifacts are built for exactly one ABI: the phone target. That also
# means no --split-per-abi: a split of a single ABI adds nothing but a per-ABI
# versionCode (2001 for arm64-v8a), which no longer matches the `+<build>`
# number in pubspec.yaml that the release and F-Droid metadata declare. Flutter
# keeps APKs from earlier builds in the output directory, so build and copy by
# name instead of globbing.
ANDROID_ABI ?= arm64-v8a
FLUTTER_BIN ?= flutter
# Maps a Flutter ABI name to the value --target-platform expects.
target_platform = $(if $(filter arm64-v8a,$(1)),android-arm64,$(if $(filter armeabi-v7a,$(1)),android-arm,android-x64))
ANDROID_TARGET_PLATFORM := $(call target_platform,$(ANDROID_ABI))
APK_OUT := app/build/app/outputs/flutter-apk
ANDROID_APK := $(APK_OUT)/app-release.apk
ANDROID_DEBUG_APK := $(APK_OUT)/app-debug.apk

# Removes APKs from earlier builds (including split-per-ABI leftovers), so
# neither `release-all` nor `install` can pick up a stale artifact. Only the
# artifacts of the build type being produced are pruned, so a debug build keeps
# a release APK. $(1) is the APK build type (debug/release).
define prune_stale_apks
	@for f in $(APK_OUT)/app*.apk; do \
		[ -e "$$f" ] || continue; \
		case "$$f" in \
			*"/app-$(1).apk") ;; \
			*) echo "Removing stale $$f"; rm -f "$$f" "$$f".sha1 ;; \
		esac; \
	done
endef

stale-android-apks-debug:
	$(call prune_stale_apks,debug)

stale-android-apks-release:
	$(call prune_stale_apks,release)

# The Rust engine script installs one cdylib per configured ABI into jniLibs.
# Leftovers from an earlier ABI would otherwise be packaged (or silently stale)
# in a later build of a different ABI.
stale-android-jnilibs:
	@for d in app/android/app/src/main/jniLibs/*/; do \
		[ -d "$$d" ] || continue; \
		case "$${d%/}" in \
			*"/jniLibs/$(ANDROID_ABI)") ;; \
			*) echo "Removing stale $${d%/}"; rm -rf "$$d" ;; \
		esac; \
	done

build: stale-android-apks-debug maplibre-fdroid-clean
	cd app && flutter build apk --debug --target-platform $(ANDROID_TARGET_PLATFORM) \
		--dart-define=USE_DEVICE_GPS=true --dart-define=MAP_VIEW=true

build-release: stale-android-apks-release
	ABI=$(ANDROID_ABI) ./app/tool/repro_build.sh "$(FLUTTER_BIN)"

build-linux-release: engine-build
	cd app && flutter build linux --release \
		--dart-define=USE_DEVICE_GPS=true --dart-define=MAP_VIEW=true

build-cli-release:
	cargo build --release -p gps-engine

VERSION_NAME := $(shell sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml)
RELEASE_DIR := release/v$(VERSION_NAME)

release-all: build-release build-linux-release build-cli-release
	mkdir -p $(RELEASE_DIR)
	rm -f $(RELEASE_DIR)/*.apk
	cp $(ANDROID_APK) $(RELEASE_DIR)/
	cp target/release/gps-engine $(RELEASE_DIR)/gps-engine
	rm -rf $(RELEASE_DIR)/linux-bundle $(RELEASE_DIR)/against_yesterday-linux-x64.tar.gz
	tar -C app/build/linux/x64/release -czf $(RELEASE_DIR)/against_yesterday-linux-x64.tar.gz bundle
	@echo "Release artifacts copied to $(RELEASE_DIR)"

# Reusable F-Droid/local reproducibility checks (see app/tool/fdroid_repro.sh).
# REPRO_ABI selects the Android ABI to test (default: arm64-v8a).
# REPRO_REF compares build output against a reference APK/dir/hash file.
REPRO_ABI ?= arm64-v8a
REPRO_ARTIFACT := $(APK_OUT)/app-release.apk
REPRO_BUILD_CMD := ABI=$(REPRO_ABI) ./app/tool/repro_build.sh "$(FLUTTER_BIN)"
REPRO_CLEAN_CMD := rm -rf app/build && cargo clean && rm -rf app/android/app/src/main/jniLibs

repro-check:
	./app/tool/fdroid_repro.sh \
		--twice \
		--clean-cmd "$(REPRO_CLEAN_CMD)" \
		--build-cmd "$(REPRO_BUILD_CMD)" \
		--artifacts "$(REPRO_ARTIFACT)"

repro-compare:
	@if [ -z "$(REPRO_REF)" ]; then echo "Usage: make repro-compare REPRO_REF=/path/to/reference-apk-or-dir"; exit 2; fi
	./app/tool/fdroid_repro.sh \
		--clean-cmd "$(REPRO_CLEAN_CMD)" \
		--build-cmd "$(REPRO_BUILD_CMD)" \
		--artifacts "$(REPRO_ARTIFACT)" \
		--reference "$(REPRO_REF)"

run: engine-build
	cd app && flutter run

run-linux: engine-build
	cd app && flutter run -d linux

run-cli: engine-build
	cargo run --release -p gps-engine -- $(filter-out $@ gps-engine,$(MAKECMDGOALS))

# Allow `make run-cli <command> [args...]` (a stray `gps-engine` token is
# tolerated) without make treating the extra tokens as targets.
%: FORCE
	@:

FORCE:
.PHONY: FORCE

# Builds the debug APK (with the Android arm64 cdylib bundled, so the app
# auto-selects the native Rust engine) and sideloads it into the connected
# device/emulator.
install: maplibre-fdroid-clean engine-android build
	@APK=$(ANDROID_DEBUG_APK); \
	echo "Installing $$APK"; \
	adb install -r "$$APK"

test-rust-engine: engine-build
	cd app && flutter test --dart-define=REQUIRE_RUST_ENGINE=true

lint:
	cd app && flutter analyze

# Re-runs the date-label assertions under a DST timezone, where consecutive
# local midnights are 23 hours apart (see CHANGELOG, Unreleased).
tz-test:
	cd app && TZ=Europe/Berlin flutter test test/route_library_test.dart

# Connected engine suites run on an emulator (x86_64) or a physical device
# (arm64-v8a). Build only the ABI the attached device can load instead of
# cross-compiling both every run; with no device yet (the harness boots one)
# both are built so the library resolves either way. Override with
# CONNECTED_ABIS when targeting a device that is not attached yet.
CONNECTED_ABIS ?= $(shell adb $(if $(ANDROID_SERIAL),-s $(ANDROID_SERIAL),) shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
ifeq ($(strip $(CONNECTED_ABIS)),)
CONNECTED_ABIS := arm64-v8a x86_64
endif

connected-test:
	cd app && ./tool/android_integration_test.sh

connected-test-engine:
	ABIS="$(CONNECTED_ABIS)" ./app/tool/build_rust_engine_android.sh
	cd app && ./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true

# Real-receiver suite: fixes simulated through the emulator geo console.
connected-test-gps:
	ABIS="$(CONNECTED_ABIS)" ./app/tool/build_rust_engine_android.sh
	cd app && ./tool/android_integration_test.sh --device-gps --dart-define=USE_RUST_ENGINE=true

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

# Python bindings (python/, built with maturin/PyO3 against rust/gps-engine).
# Uses a local virtual environment at $(PYTHON_VENV) by default.
PYTHON ?= python3
PYTHON_VENV ?= python/.venv
PYTHON_BIN := $(PYTHON_VENV)/bin/python
PYTHON_PIP := $(PYTHON_VENV)/bin/pip
MATURIN := $(PYTHON_VENV)/bin/maturin

python-venv:
	@cd python && \
	if [ ! -x .venv/bin/python ]; then $(PYTHON) -m venv .venv; fi && \
	.venv/bin/pip install --upgrade pip maturin pytest

python-develop: python-venv
	cd python && .venv/bin/maturin develop

python-build: python-venv
	cd python && .venv/bin/maturin build --release

python-test: python-develop
	cd python && .venv/bin/python -m pytest -q

python-clean:
	rm -rf python/target python/build python/dist python/.pytest_cache
	find python -type d -name __pycache__ -prune -exec rm -rf {} +

# Removes Google Play Services from the cached MapLibre plugin before a build,
# so device artifacts stay F-Droid-clean. Safe to run repeatedly.
maplibre-fdroid-clean:
	./app/tool/fdroid_prebuild.sh

engine-android: stale-android-jnilibs
	ABIS=$(ANDROID_ABI) ./app/tool/build_rust_engine_android.sh

check:
	cd app && flutter analyze
	cargo fmt --all --check
	cargo clippy --all-targets --all-features -- -D warnings

check-versions: ## Verify toolchain versions are consistent across sources
	@echo "== Toolchain versions =="
	@echo "Rust toolchain: $$(sed -n 's/^channel *= *\"\([^\"]*\)\".*/\1/p' rust-toolchain.toml)"
	@echo "Flutter (CI):   $$(grep 'flutter-version:' .github/workflows/ci.yml | head -1 | sed -E "s/.*flutter-version: *'([^']+)'.*/\1/")"
	@echo "NDK (gradle):   $$(grep ndkVersion app/android/app/build.gradle.kts | sed -E 's/.*ndkVersion *= *"([^"]+)".*/\1/')" 
	@echo "NDK (script):   (resolved from build.gradle.kts at build time)"
	@echo "versions.yml:"
	@cat versions.yml | grep -v '^#' | grep -v '^$$'

test:
	cd app && flutter test
	cargo test --all-features

ci-test:
	CI=1 bash app/tool/full_test.sh

full-test:
	bash app/tool/full_test.sh

full-test-device:
	DEVICE=1 bash app/tool/full_test.sh


clean: python-clean
	cd app && flutter clean
	cargo clean
	rm -rf app/android/app/src/main/jniLibs/*/libgps_engine.so
	-rmdir app/android/app/src/main/jniLibs/* 2>/dev/null || true
	-rmdir app/android/app/src/main/jniLibs 2>/dev/null || true