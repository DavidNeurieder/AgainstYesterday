// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Persistence for routes and activities (M10, §27).
///
/// Repositories own the data and expose it to the UI as [Notifier]s, so Home
/// and Record stay reactive without routing data through the recording
/// controller. By default a [`NoopPersistenceStore`] keeps state in memory
/// (empty catalog, hermetic widget tests); swap in a [`JsonFileStore`] to make
/// it survive restarts:
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     persistenceStoreProvider.overrideWithValue(
///       JsonFileStore(Directory('data')),
///     ),
///   ],
/// )
/// ```
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/models.dart';
import 'serialization.dart';

/// Backing store for one or more JSON documents. Read is synchronous because
/// the documents are small; write is atomic (temp file + rename).
abstract class PersistenceStore {
  /// Returns the document for [key], or `null` when none exists.
  String? read(String key);

  /// Stores [value] under [key], atomically when the backend supports it.
  Future<void> write(String key, String value);

  /// Removes the document at [key]. No-op when no such document exists.
  void remove(String key);
}

/// In-memory, stateless store — nothing is persisted to disk.
class NoopPersistenceStore implements PersistenceStore {
  const NoopPersistenceStore();

  @override
  String? read(String key) => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  void remove(String key) {}
}

/// In-memory store that keeps documents for the app's lifetime. Useful for
/// widget tests that need a real (non-Noop) backend without the file system.
class MemoryPersistenceStore implements PersistenceStore {
  MemoryPersistenceStore();

  final Map<String, String> _docs = {};

  @override
  String? read(String key) => _docs[key];

  @override
  Future<void> write(String key, String value) async => _docs[key] = value;

  @override
  void remove(String key) => _docs.remove(key);
}

/// Best-effort storage reads: a device with flaky storage degrades to the
/// seeded defaults instead of crashing the UI (failure injection, Phase 13).
String? readBestEffort(PersistenceStore store, String key) {
  try {
    return store.read(key);
  } catch (_) {
    return null;
  }
}

/// Best-effort storage writes: the in-memory repositories stay authoritative,
/// so a failed disk write never produces an unhandled async exception.
Future<void> writeBestEffort(
  PersistenceStore store,
  String key,
  String value,
) async {
  try {
    await store.write(key, value);
  } catch (_) {
    // Degraded storage: nothing to recover — the in-memory state persists.
  }
}

/// A flat JSON-file store rooted at a directory.
class JsonFileStore implements PersistenceStore {
  JsonFileStore(this.directory);

  final Directory directory;

  @override
  String? read(String key) {
    final file = File('${directory.path}/$key.json');
    if (!file.existsSync()) {
      return null;
    }
    return file.readAsStringSync();
  }

  @override
  Future<void> write(String key, String value) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/$key.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(file.path);
  }
/// Removes a document by deleting its file.
  @override
  void remove(String key) {
    final file = File('${directory.path}/$key.json');
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

/// The backing store for every repository. Defaults to in-memory.
final persistenceStoreProvider = Provider<PersistenceStore>(
  (_) => const NoopPersistenceStore(),
);

/// Routed catalog — what Home and Record see.
final routeRepositoryProvider =
    NotifierProvider<RouteRepository, List<Route>>(RouteRepository.new);

/// Activity history — newest first.
final activityRepositoryProvider =
    NotifierProvider<ActivityRepository, List<Activity>>(
        ActivityRepository.new);

/// The interrupted run that can be resumed (M13, §28). `null` when no run is
/// in progress or the last one finished cleanly.
final runSnapshotProvider =
    NotifierProvider<RunSnapshotRepository, RunSnapshot?>(
        RunSnapshotRepository.new);

/// Routes can be stored, loaded, and (later, M12) grown by saving new runs.
class RouteRepository extends Notifier<List<Route>> {
  @override
  List<Route> build() {
    ref.watch(persistenceStoreProvider);
    final raw = readBestEffort(ref.read(persistenceStoreProvider), _routesKey);
    if (raw != null) {
      try {
        return parseRouteList(raw);
      } on FormatException {
        // Corrupt store: start from an empty catalog.
      } on TypeError {
        // Structurally valid JSON with the wrong shape.
      }
    }
    return const [];
  }

  /// Upserts [route] into the catalog.
  Future<void> saveRoute(Route route) async {
    final index = state.indexWhere((r) => r.id == route.id);
    final next = [...state];
    if (index >= 0) {
      next[index] = route;
    } else {
      next.add(route);
    }
    state = next;
    await _persist();
  }

  Future<void> _persist() async {
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return;
    }
    await writeBestEffort(store, _routesKey, routeListToJson(state));
  }

  /// Drops every route from the catalog (Settings → Delete all data, M21).
  void clear() => state = const [];

  static const _routesKey = 'routes';
}

/// Completed activities can be stored and reloaded as history.
class ActivityRepository extends Notifier<List<Activity>> {
  @override
  List<Activity> build() {
    ref.watch(persistenceStoreProvider);
    final raw =
        readBestEffort(ref.read(persistenceStoreProvider), _activitiesKey);
    if (raw != null) {
      try {
        return parseActivityList(raw);
      } on FormatException {
        // Corrupt store: start from an empty history.
      } on TypeError {
        // Structurally valid JSON with the wrong shape.
      }
    }
    return const [];
  }

  /// Inserts [activity] at the top of the history (newest first).
  ///
  /// Returns whether the disk write landed (§33): the in-memory list is
  /// updated either way, so a `false` only means "retry the write".
  Future<bool> saveActivity(Activity activity) async {
    state = [activity, ...state.where((a) => a.id != activity.id)];
    return _persist();
  }

  Future<bool> _persist() async {
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return true;
    }
    try {
      await store.write(_activitiesKey, activityListToJson(state));
      return true;
    } catch (_) {
      // Degraded storage: the in-memory history stays authoritative.
      return false;
    }
  }

  /// Drops every activity from history (Settings → Delete all data, M21).
  void clear() => state = const [];

  static const _activitiesKey = 'activities';
}

/// Loads and stores the interrupted-run snapshot. Survives process death so
/// the next launch can offer to resume (§28).
class RunSnapshotRepository extends Notifier<RunSnapshot?> {
  @override
  RunSnapshot? build() {
    ref.watch(persistenceStoreProvider);
    final raw = readBestEffort(ref.read(persistenceStoreProvider), _key);
    if (raw == null || raw.trim() == 'null') {
      return null;
    }
    try {
      return parseRunSnapshot(raw);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Overwrites the snapshot (called while a run is active and on lifecycle
  /// transitions), or null to clear it once the run is finished/dismissed.
  ///
  /// Returns whether the disk write landed (§33); the in-memory value is
  /// updated either way.
  Future<bool> save(RunSnapshot? snapshot) async {
    if (snapshot == null) {
      state = null;
      return _clear();
    }
    state = snapshot;
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return true;
    }
    try {
      await store.write(_key, runSnapshotToJson(snapshot));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _clear() async {
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return true;
    }
    try {
      await store.write(_key, 'null');
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _key = 'run_snapshot';
}