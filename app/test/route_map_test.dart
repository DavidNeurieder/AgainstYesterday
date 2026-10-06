// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/widgets/route_map.dart';

void main() {
  const demo = <GeoPoint>[
    GeoPoint(latitude: 51.9600, longitude: 7.6300),
    GeoPoint(latitude: 51.9610, longitude: 7.6315),
    GeoPoint(latitude: 51.9605, longitude: 7.6330),
    GeoPoint(latitude: 51.9595, longitude: 7.6320),
  ];

  Widget host({GeoPoint? you, GeoPoint? ghost, double progress = 0.2}) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: RouteMap(
            geometry: demo,
            you: you ?? demo.first,
            youProgress: progress,
            ghost: ghost,
            name: 'River Loop',
          ),
        ),
      ),
    );
  }

  testWidgets('renders YOU and PB markers', (tester) async {
    await tester.pumpWidget(
      host(
        you: const GeoPoint(latitude: 51.9603, longitude: 7.6310),
        ghost: const GeoPoint(latitude: 51.9602, longitude: 7.6308),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('you-marker')), findsOneWidget);
    expect(find.byKey(const ValueKey('ghost-marker')), findsOneWidget);
    expect(find.text('PB'), findsOneWidget);
    expect(find.text('River Loop'), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsNothing);
  });

  testWidgets('no ghost leaves the marker slot empty', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byKey(const ValueKey('you-marker')), findsOneWidget);
    expect(find.byKey(const ValueKey('ghost-marker')), findsOneWidget);
    expect(find.text('PB'), findsNothing);
  });

  testWidgets('pan detaches the camera, Recenter re-attaches', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byIcon(Icons.my_location), findsNothing);

    await tester.drag(find.byType(RouteMap), const Offset(60, 30));
    await tester.pump();
    expect(find.byIcon(Icons.my_location), findsOneWidget);

    await tester.tap(find.byIcon(Icons.my_location));
    await tester.pump();
    expect(find.byIcon(Icons.my_location), findsNothing);
  });
}