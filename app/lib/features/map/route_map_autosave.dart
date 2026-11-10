// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Saves a route's map locally when the route or one of its runs is opened.
///
/// The offline region is keyed by route, so every run of the same course uses
/// the same saved map. This widget is the automatic trigger: it asks the
/// repository to ensure the region once per screen open (and again if the
/// screen switches to another route), without changing anything the user sees.
/// Builds that cannot store tiles no-op, and a failed download is retried the
/// next time the route is opened.
library;

import 'package:flutter/widgets.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/models.dart';
import 'offline_region_repository.dart';

class RouteMapAutosave extends ConsumerStatefulWidget {
  const RouteMapAutosave({super.key, required this.route});

  final Route route;

  @override
  ConsumerState<RouteMapAutosave> createState() => _RouteMapAutosaveState();
}

class _RouteMapAutosaveState extends ConsumerState<RouteMapAutosave> {
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant RouteMapAutosave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.id != widget.route.id) {
      _schedule();
    }
  }

  /// Deferred to after the frame: [OfflineRegionRepository.ensureRoute] may
  /// start the download synchronously, and provider state must not change
  /// while the widget tree is building.
  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref
          .read(offlineRegionRepositoryProvider.notifier)
          .ensureRoute(widget.route);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
