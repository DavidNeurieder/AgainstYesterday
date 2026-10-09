// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/persistence/serialization.dart';

Route _route({
  String id = 'river-loop',
  String name = 'River Loop',
  int attempts = 12,
  double? pbSeconds = 1470,
  List<GeoPoint>? geometry,
}) =>
    Route(
      id: id,
      name: name,
      distance: const Distance.kilometers(4.76),
      geometry: geometry ?? FakeEngineService.riverLoop,
      attemptCount: attempts,
      personalBest: pbSeconds == null ? null : Elapsed.seconds(pbSeconds),
    );

Activity _activity({
  String id = 'act-x',
  String? routeId = 'river-loop',
  DateTime? startedAt,
  List<TrackPoint>? track,
}) =>
    Activity(
      id: id,
      routeId: routeId,
      startedAt: startedAt ?? DateTime.utc(2026, 1, 2, 3, 4, 5),
      duration: const Elapsed.seconds(1502),
      distance: const Distance.kilometers(4.75),
      performance: '24:22 · 1st',
      track: track,
    );

void main() {
  group('serialization round-trips', () {
    test('route list survives a JSON round-trip', () {
      final routes = [
        _route(pbSeconds: null),
        _route(id: 'x', name: 'X', attempts: 0, pbSeconds: null),
      ];
      final decoded = parseRouteList(routeListToJson(routes));
      expect(decoded, hasLength(2));
      expect(decoded[1].id, 'x');
      expect(decoded[0].personalBest, isNull);
      expect(decoded[1].geometry.first, FakeEngineService.riverLoop.first);
      expect(decoded[1].geometry.length, FakeEngineService.riverLoop.length);
    });

    test('a route with a PB and full geometry survives', () {
      final decoded = parseRouteList(routeListToJson([_route()])).single;
      expect(decoded.attemptCount, 12);
      expect(decoded.personalBest?.seconds, 1470);
      expect(decoded.distance.meters, closeTo(4760, 5));
      expect(decoded.geometry, FakeEngineService.riverLoop);
    });

    test('activity with a full track survives a JSON round-trip', () {
      final track = [
        TrackPoint(
          position: const GeoPoint(latitude: 52.505, longitude: 13.360),
          altitudeMeters: 34,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1234567890,
              isUtc: true),
        ),
        TrackPoint(
          position: const GeoPoint(latitude: 52.500, longitude: 13.362),
          timestamp: DateTime.fromMillisecondsSinceEpoch(1234568890,
              isUtc: true),
        ),
      ];
      final activity =
          parseActivityList(activityListToJson([_activity(track: track)]))
              .single;
      expect(activity.id, 'act-x');
      expect(activity.routeId, 'river-loop');
      expect(activity.startedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(activity.duration?.seconds, 1502);
      expect(activity.performance, '24:22 · 1st');
      expect(activity.track, hasLength(2));
      expect(activity.track![0].altitudeMeters, 34);
      expect(activity.track![0].timestamp.millisecondsSinceEpoch, 1234567890);
      expect(activity.track![1].position, const GeoPoint(latitude: 52.5, longitude: 13.362));
    });

    test('an activity without a track decodes as null track', () {
      final decoded = parseActivityList(activityListToJson([_activity()]));
      expect(decoded.single.track, isNull);
    });

    test('an activity without a route decodes as null routeId', () {
      final decoded =
          parseActivityList(activityListToJson([_activity(routeId: null)]));
      expect(decoded.single.routeId, isNull);
    });
  });

  group('in-memory repositories', () {
    test('routes start empty, then saveRoute appends and upserts by id', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(routeRepositoryProvider), isEmpty);

      await c.read(routeRepositoryProvider.notifier).saveRoute(
            _route(id: 'river-loop', name: 'Renamed', attempts: 99),
          );
      var cat = c.read(routeRepositoryProvider);
      expect(cat, hasLength(1));
      expect(cat.single.name, 'Renamed');
      expect(cat.single.attemptCount, 99);

      await c.read(routeRepositoryProvider.notifier).saveRoute(
            _route(id: 'new-route', name: 'New Route', attempts: 1),
          );
      cat = c.read(routeRepositoryProvider);
      expect(cat, hasLength(2));
      expect(cat.last.name, 'New Route');
    });

    test('activities start empty and saveActivity dedupes by id', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(activityRepositoryProvider), isEmpty);

      await c
          .read(activityRepositoryProvider.notifier)
          .saveActivity(_activity(id: 'act-005'));
      var history = c.read(activityRepositoryProvider);
      expect(history, hasLength(1));
      expect(history.first.id, 'act-005');

      // Re-saving the same id moves it up without duplicating.
      await c
          .read(activityRepositoryProvider.notifier)
          .saveActivity(_activity(id: 'act-005', routeId: null));
      history = c.read(activityRepositoryProvider);
      expect(history, hasLength(1));
      expect(history.first.id, 'act-005');
      expect(history.first.routeId, isNull);
    });

    test('deleteActivity drops exactly the named run', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final repo = c.read(activityRepositoryProvider.notifier);
      await repo.saveActivity(_activity(id: 'a'));
      await repo.saveActivity(_activity(id: 'b'));
      await repo.saveActivity(_activity(id: 'c'));

      expect(await repo.deleteActivity('b'), isTrue);
      // Newest first, and only the named run is gone.
      expect(c.read(activityRepositoryProvider).map((a) => a.id), ['c', 'a']);

      // Deleting an unknown id is a no-op that still reports success.
      expect(await repo.deleteActivity('missing'), isTrue);
      expect(c.read(activityRepositoryProvider), hasLength(2));
    });
  });

  group('JSON file store', () {
    late Directory temp;
    late JsonFileStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('gps_persist_');
      store = JsonFileStore(temp);
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('routes persist across repository restarts', () async {
      final first = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(first.dispose);
      await first.read(routeRepositoryProvider.notifier)
          .saveRoute(_route(id: 'saved', name: 'Saved route'));

      final second = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(second.dispose);
      final routes = second.read(routeRepositoryProvider);
      expect(routes.map((r) => r.id), contains('saved'));
      expect(
        routes.where((r) => r.id == 'saved').single.name,
        'Saved route',
      );
    });

    test('activities persist across repository restarts', () async {
      final track = [
        TrackPoint(
          position: const GeoPoint(latitude: 52.5, longitude: 13.36),
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        ),
      ];
      final first = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(first.dispose);
      await first.read(activityRepositoryProvider.notifier)
          .saveActivity(_activity(id: 'kept', track: track));

      final second = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(second.dispose);
      final kept =
          second.read(activityRepositoryProvider).where((a) => a.id == 'kept');
      expect(kept, hasLength(1));
      expect(kept.single.track, hasLength(1));
      expect(kept.single.duration?.seconds, 1502);
    });

    test('a deleted activity stays deleted across repository restarts',
        () async {
      final first = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(first.dispose);
      final repo = first.read(activityRepositoryProvider.notifier);
      await repo.saveActivity(_activity(id: 'keep'));
      await repo.saveActivity(_activity(id: 'drop'));
      await repo.deleteActivity('drop');

      final second = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(second.dispose);
      expect(
        second.read(activityRepositoryProvider).map((a) => a.id),
        ['keep'],
      );
    });

    test('a corrupt document degrades to an empty catalog', () {
      temp.createSync(recursive: true);
      File('${temp.path}/routes.json').writeAsStringSync('{not json');
      final c = ProviderContainer(
        overrides: [persistenceStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      expect(c.read(routeRepositoryProvider), isEmpty);
    });
  });
}