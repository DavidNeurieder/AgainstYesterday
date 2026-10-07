// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Dependency injection root for the app (§4, §6).
///
/// The rest of the app consumes `EngineService` — never raw FFI. The engine is
/// selected at build time from `USE_RUST_ENGINE`:
///
///  * not set — auto: the native Rust engine is used when its library loads,
///    otherwise the deterministic [FakeEngineService] (the dev/demo fallback);
///  * `true` — require the Rust engine; a missing library becomes a startup
///    error;
///  * `false` — always the fake.
///
/// On Android the bare name `libgps_engine.so` resolves to the ABI-appropriate
/// cdylib that `app/tool/build_rust_engine_android.sh` bundles into the APK. On
/// host workloads point the build at the library with
/// `--dart-define=GPS_ENGINE_LIB=/path/to/libgps_engine.so`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/device_gps_source.dart';
import '../engine/engine_service.dart';
import '../engine/fake_engine.dart';
import '../engine/rust_engine_service.dart';

/// Raw `USE_RUST_ENGINE` — `''` (auto), `'true'` (require), `'false'` (fake).
const String _useRustEngine = String.fromEnvironment('USE_RUST_ENGINE');

/// Whether the developer diagnostics entry point is exposed (M15 Phase 10).
/// Build with `--dart-define=DEV_TOOLS=true` to enable on devices; tests
/// override [devToolsEnabledProvider] directly.
const bool devToolsEnabled = bool.fromEnvironment('DEV_TOOLS');

/// Gate for the diagnostics screen entry button.
final devToolsEnabledProvider = Provider<bool>((_) => devToolsEnabled);

/// The engine facade the whole app talks to (§6).
final engineServiceProvider = Provider<EngineService>((_) {
  if (_useRustEngine == 'false') {
    return FakeEngineService();
  }
  final libraryPath = const String.fromEnvironment('GPS_ENGINE_LIB');
  try {
    return RustEngineService.open(
      libraryPath.isEmpty ? 'libgps_engine.so' : libraryPath,
    );
  } on ArgumentError {
    if (_useRustEngine == 'true') {
      rethrow;
    }
    // The native library could not be loaded — a dev build without the cdylib,
    // or a target with no bundled engine — so fall back to the deterministic
    // demo engine. The diagnostics readout names whichever one is in use.
    return FakeEngineService();
  }
});

/// Raw `USE_DEVICE_GPS` — `'true'` reads the live run from the phone receiver
/// (real GPS); anything else replays the deterministic demo timeline.
const String _useDeviceGps = String.fromEnvironment('USE_DEVICE_GPS');

/// The live GPS source, or `null` to keep the deterministic scenario timeline.
///
/// `USE_DEVICE_GPS=true` installs the real [DeviceGpsSource]; host tests and
/// the E2E run without the define and override this provider directly when
/// they want to exercise the device path with a canned fix stream.
final deviceGpsProvider = Provider<GpsSource?>(
  (_) => _useDeviceGps == 'true' ? const DeviceGpsSource() : null,
);