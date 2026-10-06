// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// FFI bindings to the Rust engine's CDylib (M9).
///
/// This is the only file in the app that touches raw FFI symbols — every other
/// layer talks to [`EngineService`]. Requests/responses are the little-endian
/// binary buffers documented in `rust/gps-engine/src/capi.rs`; the model
/// conversion lives in `rust_engine_service.dart`.
///
/// Memory returned by the library is released with its own `gps_free`, never
/// Dart's GC.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _NativeFn = Int32 Function(
  Pointer<Uint8>,
  Uint64,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint64>,
);
typedef _DartFn = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint64>,
);

/// Error thrown when the Rust engine reports a nonzero status.
class GpsEngineException implements Exception {
  const GpsEngineException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'GpsEngineException($status): $message';
}

/// Loaded `libgps_engine` shared library.
final class GpsEngineFfi {
  GpsEngineFfi(this._lib);

  /// Loads the engine from an explicit path (host/test builds).
  factory GpsEngineFfi.open(String path) =>
      GpsEngineFfi(DynamicLibrary.open(path));

  final DynamicLibrary _lib;

  late final _DartFn _processTrack = _bind('gps_process_track');
  late final _DartFn _matchRoutes = _bind('gps_match_routes');
  late final _DartFn _createAttempt = _bind('gps_create_attempt');
  late final _DartFn _ghostStateAt = _bind('gps_ghost_state_at');
  late final _DartFn _generateRecording = _bind('gps_generate_recording');
  late final void Function(Pointer<Uint8>) _free =
      _lib.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
          'gps_free');
  late final Pointer<Utf8> Function() _version =
      _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'gps_capi_version');
  late final Pointer<Utf8> Function() _lastError =
      _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'gps_last_error');

  _DartFn _bind(String name) => _lib.lookupFunction<_NativeFn, _DartFn>(name);

  /// Engine version string (`<major>.<minor>.<patch>`).
  String get version => _version().toDartString();

  /// Human-readable text of the most recent engine error.
  String get lastError => _lastError().toDartString();

  Uint8List processTrack(Uint8List request) =>
      _invoke(_processTrack, request, 'process_track');
  Uint8List matchRoutes(Uint8List request) =>
      _invoke(_matchRoutes, request, 'match_routes');
  Uint8List createAttempt(Uint8List request) =>
      _invoke(_createAttempt, request, 'create_attempt');
  Uint8List ghostStateAt(Uint8List request) =>
      _invoke(_ghostStateAt, request, 'ghost_state_at');
  Uint8List generateRecording(Uint8List request) =>
      _invoke(_generateRecording, request, 'generate_recording');

  Uint8List _invoke(_DartFn fn, Uint8List request, String op) {
    final input = calloc<Uint8>(request.length);
    if (request.isNotEmpty) {
      input.asTypedList(request.length).setAll(0, request);
    }
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Uint64>();

    try {
      final status = fn(input, request.length, out, outLen);
      final outputPtr = out.value;
      final len = outLen.value;
      final data = len == 0
          ? Uint8List(0)
          : Uint8List.fromList(outputPtr.asTypedList(len));
      final message = status == 0 ? null : lastError;
      if (outputPtr.address != 0) {
        _free(outputPtr);
      }
      if (status != 0) {
        throw GpsEngineException(status, message ?? 'engine error in $op');
      }
      return data;
    } finally {
      calloc.free(input);
      calloc.free(out);
      calloc.free(outLen);
    }
  }
}