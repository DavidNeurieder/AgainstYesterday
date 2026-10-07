// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Snapshot & history recovery edge cases (test plan Phase 6).
///
/// Targets: a corrupted or missing store, a snapshot referencing a route that
/// no longer exists, and malformed JSON documents — all of which must degrade
/// predictably instead of crashing or poisoning the app.
library;

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/persistence/serialization.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  group('clearing on completion', () {
    test('finishing a run clears the interrupted-run snapshot', () {
      fakeAsync((async) {
        final store = MemoryPersistenceStore();
        final c = ProviderContainer(
          overrides: [
            persistenceStoreProvider.overrideWithValue(store),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 5));
        ctrl.appBackgrounded();
        expect(store.read('run_snapshot'), isNotNull);

        ctrl.finishRun();
        async.elapse(const Duration(milliseconds: 500));
        expect(c.read(recordingControllerProvider)!.status, RunStatus.completed);
        expect(store.read('run_snapshot'), 'null');
      });
    });
  });

  group('resumeFromSnapshot recovery', () {
    ProviderContainer container(FakeAsync async, PersistenceStore store) {
      final c = ProviderContainer(
        overrides: [
          persistenceStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      keepAlive(c);
      return c;
    }

    test('snapshot with a stale route resumes safely and keeps moving', () {
      fakeAsync((async) {
        final c = container(async, MemoryPersistenceStore());
        final ctrl = c.read(recordingControllerProvider.notifier);
        final snapshot = RunSnapshot(
          status: RunStatus.running,
          startedAt: DateTime.utc(2026, 1, 1, 10),
          movingSeconds: 120,
          distanceMeters: 400,
          loopMeters: 4760,
          routeId: 'stale-route', // not present in the catalog any more
        );
        ctrl.resumeFromSnapshot(snapshot);
        async.flushMicrotasks();

        final restored = c.read(recordingControllerProvider)!;
        expect(restored.status, RunStatus.running);
        expect(restored.elapsed.seconds, closeTo(120, 0.01));
        expect(restored.distance.meters, closeTo(400, 0.01));
        expect(restored.route, isNull); // unknown route dropped, not crashed
        expect(restored.gpsQuality, 'good');

        // Movement continues from the restored distance.
        async.elapse(const Duration(seconds: 2));
        expect(c.read(recordingControllerProvider)!.distance.meters,
            greaterThan(400));
      });
    });

    test('a far-along snapshot never breaches the loop length', () {
      fakeAsync((async) {
        final c = container(async, MemoryPersistenceStore());
        final ctrl = c.read(recordingControllerProvider.notifier);
        const loopMeters = 4760.0;
        final snapshot = RunSnapshot(
          status: RunStatus.running,
          startedAt: DateTime.utc(2026, 1, 1, 10),
          movingSeconds: 1700,
          distanceMeters: 4500,
          loopMeters: loopMeters,
          routeId: null,
        );
        ctrl.resumeFromSnapshot(snapshot);
        async.flushMicrotasks();
        expect(c.read(recordingControllerProvider)!.distance.meters,
            closeTo(4500, 0.01));

        // Headless resumes clamp to the loop length recorded in the snapshot.
        async.elapse(const Duration(seconds: 300)); // long enough to lap
        expect(c.read(recordingControllerProvider)!.distance.meters,
            closeTo(loopMeters, 0.5));
        expect(c.read(recordingControllerProvider)!.routeProgress,
            lessThanOrEqualTo(1.0));
      });
    });

    test('a paused snapshot resumes paused, not running', () {
      fakeAsync((async) {
        final c = container(async, MemoryPersistenceStore());
        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.resumeFromSnapshot(
          RunSnapshot(
            status: RunStatus.paused,
            startedAt: DateTime.utc(2026, 1, 1, 10),
            movingSeconds: 60,
            distanceMeters: 200,
            loopMeters: 4760,
          ),
        );
        async.flushMicrotasks();
        expect(c.read(recordingControllerProvider)!.status, RunStatus.paused);
        // Paused on arrival: distance must not grow.
        final distance = c.read(recordingControllerProvider)!.distance.meters;
        async.elapse(const Duration(seconds: 5));
        expect(c.read(recordingControllerProvider)!.distance.meters, distance);
      });
    });

    test('resumeFromSnapshot is ignored while a session is active', () {
      fakeAsync((async) {
        final c = container(async, MemoryPersistenceStore());
        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(c.read(recordingControllerProvider)!.status, RunStatus.ready);

        ctrl.resumeFromSnapshot(
          RunSnapshot(
            status: RunStatus.running,
            startedAt: DateTime.utc(2026, 1, 1, 10),
            movingSeconds: 120,
            distanceMeters: 400,
            loopMeters: 4760,
          ),
        );
        async.flushMicrotasks();
        // The live session stays untouched.
        expect(c.read(recordingControllerProvider)!.status, RunStatus.ready);
        expect(c.read(recordingControllerProvider)!.elapsed.seconds, 0);
      });
    });
  });

  group('malformed snapshot documents', () {
    test('parseRunSnapshot throws FormatException on undecodable JSON', () {
      expect(() => parseRunSnapshot('{not json'), throwsFormatException);
      expect(() => parseRunSnapshot(''), throwsFormatException);
    });

    test('an unknown status string defaults to running', () {
      final snapshot = RunSnapshot(
        status: RunStatus.paused,
        startedAt: DateTime.utc(2026, 1, 1, 10),
        movingSeconds: 90,
        distanceMeters: 300,
        loopMeters: 4760,
      );
      final json = runSnapshotToJson(snapshot).replaceFirst(
        '"status":"paused"',
        '"status":"stale_state"',
      );
      expect(parseRunSnapshot(json).status, RunStatus.running);
    });

    test('the repository yields null for corrupt, missing, or null docs', () async {
      final dir = await Directory.systemTemp.createTemp('against_yesterday_test');
      addTearDown(() => dir.delete(recursive: true));

      RunSnapshot? buildWith(String? content) {
        final file = File('${dir.path}/run_snapshot.json');
        if (content == null) {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } else {
          file.writeAsStringSync(content);
        }
        final c = ProviderContainer(
          overrides: [
            persistenceStoreProvider
                .overrideWithValue(JsonFileStore(dir)),
          ],
        );
        addTearDown(c.dispose);
        return c.read(runSnapshotProvider);
      }

      // No file at all.
      expect(buildWith(null), isNull);

      // Literal `null` document (what a clean finish writes).
      expect(buildWith('null'), isNull);

      // Corrupt document.
      expect(buildWith('{oops'), isNull);
    });
  });

  group('corrupt history degrades to an empty history', () {
    test('a corrupt activities document recovers to an empty history', () async {
      final dir = await Directory.systemTemp.createTemp('against_yesterday_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonFileStore(dir);
      File('${dir.path}/activities.json').writeAsStringSync('{oops');

      final c = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);

      final history = c.read(activityRepositoryProvider);
      expect(history, isEmpty);
    });
  });
}