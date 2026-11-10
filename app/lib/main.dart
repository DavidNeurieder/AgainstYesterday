// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'features/map/offline_region_downloader.dart';
import 'persistence/persistence.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A real install persists to the app documents directory (M10's device
  // store); widget tests and the demo keep their hermetic in-memory stores
  // by overriding the provider in their own scope.
  final directory = await getApplicationDocumentsDirectory();
  final mapCacheDirectory = Directory('${directory.path}/map_cache');
  runApp(
    ProviderScope(
      overrides: [
        persistenceStoreProvider.overrideWithValue(JsonFileStore(directory)),
        mapTileCacheDirectoryProvider.overrideWithValue(mapCacheDirectory),
      ],
      child: const AgainstYesterdayApp(),
    ),
  );
}
