// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Units value objects mirroring the Rust engine's newtypes.
///
/// These are lightweight, immutable, pure-Dart values used across the app.
/// They intentionally avoid Flutter imports so they can be tested with plain
/// `flutter test`.
library;

/// Distance units for display (M21, §26). The engine works in meters and
/// seconds regardless; unit choice is purely presentational.
enum Units {
  kilometers,
  miles;

  /// The short suffix used after pace values, e.g. "5:23 /km".
  String get paceSuffix => switch (this) {
        Units.kilometers => '/km',
        Units.miles => '/mi',
      };

  String get label => switch (this) {
        Units.kilometers => 'Kilometers',
        Units.miles => 'Miles',
      };
}

/// A distance in meters.
class Distance {
  const Distance._(this.meters);

  const Distance.zero() : this._(0);
  const Distance.meters(double meters) : this._(meters);

  const Distance.kilometers(double kilometers) : this._(kilometers * 1000.0);

  final double meters;

  Distance operator +(Distance other) => Distance.meters(meters + other.meters);
  Distance operator -(Distance other) => Distance.meters(meters - other.meters);
  Distance operator *(double factor) => Distance.meters(meters * factor);

  @override
  bool operator ==(Object other) =>
      other is Distance && (meters - other.meters).abs() < 1e-9;
  @override
  int get hashCode => meters.floor();

  Distance abs() => Distance.meters(meters.abs());

  double get kilometers => meters / 1000.0;
  double get miles => meters / 1609.344;

  /// "412 m" below one thousand meters, otherwise "4.12 km".
  String format() => formatWith(Units.kilometers);

  /// Formats for the chosen display unit (M21, §26).
  ///
  /// Kilometers fall back to meters under one thousand; miles fall back to
  /// meters under 161 m (0.1 mi). E.g. "6.21 mi" for ten kilometers.
  String formatWith(Units units) {
    switch (units) {
      case Units.kilometers:
        if (meters.abs() < 1000.0) {
          return '${meters.round()} m';
        }
        return '${kilometers.toStringAsFixed(2)} km';
      case Units.miles:
        if (meters.abs() < 160.9344) {
          return '${meters.round()} m';
        }
        return '${miles.toStringAsFixed(2)} mi';
    }
  }
}

/// A duration in seconds.
class Elapsed {
  const Elapsed._(this.seconds);

  const Elapsed.zero() : this._(0);
  const Elapsed.seconds(double seconds) : this._(seconds);
  const Elapsed.minutes(double minutes) : this._(minutes * 60.0);
  const Elapsed.hours(double hours) : this._(hours * 3600.0);

  final double seconds;

  Elapsed operator +(Elapsed other) => Elapsed.seconds(seconds + other.seconds);
  Elapsed operator -(Elapsed other) => Elapsed.seconds(seconds - other.seconds);

  @override
  bool operator ==(Object other) =>
      other is Elapsed && (seconds - other.seconds).abs() < 1e-9;
  @override
  int get hashCode => seconds.floor();

  int get wholeSeconds => seconds.round();

  /// "0:32" style, or "1:04:32" when an hour or more has elapsed.
  String format() {
    final total = wholeSeconds.max(0);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Always "hh:mm:ss" padded, used for charts/accessibility.
  String formatClock() {
    final total = wholeSeconds.max(0);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}

/// A speed in meters per second.
class Speed {
  const Speed._(this.metersPerSecond);

  const Speed.zero() : this._(0);
  const Speed.metersPerSecond(double metersPerSecond)
      : this._(metersPerSecond);

  /// Speed from a pace: seconds needed to cover one kilometer.
  const Speed.fromPaceSecondsPerKm(double secondsPerKm)
      : this._(secondsPerKm <= 0 ? 0 : 1000.0 / secondsPerKm);

  final double metersPerSecond;

  double get kilometersPerHour => metersPerSecond * 3.6;

  /// Seconds needed to cover one kilometer at this speed (0 when parked).
  double get paceSecondsPerKm =>
      metersPerSecond > 0 ? 1000.0 / metersPerSecond : 0;

  /// "5:23 /km" pace format; "— /km" when stationary.
  String formatPace() => formatPaceWith(Units.kilometers);

  /// Pace formatted for the chosen display unit (M21, §26): seconds per km or
  /// per mile. "— /mi" when stationary.
  String formatPaceWith(Units units) {
    final perUnit = switch (units) {
      Units.kilometers => paceSecondsPerKm,
      Units.miles => metersPerSecond > 0 ? 1609.344 / metersPerSecond : 0,
    };
    if (perUnit <= 0) {
      return '— ${units.paceSuffix}';
    }
    final whole = perUnit.round();
    final m = whole ~/ 60;
    final s = whole % 60;
    return '$m:${s.toString().padLeft(2, '0')} ${units.paceSuffix}';
  }

  /// "9.4 km/h".
  String format() => formatWith(Units.kilometers);

  /// Speed formatted for the chosen display unit (M21, §26): km/h or mph.
  String formatWith(Units units) {
    final value = switch (units) {
      Units.kilometers => kilometersPerHour,
      Units.miles => metersPerSecond * 2.2369362921,
    };
    final unit = switch (units) {
      Units.kilometers => 'km/h',
      Units.miles => 'mph',
    };
    return '${value.toStringAsFixed(1)} $unit';
  }
}

/// Small integer clamp helper so unit types stay dependency-free.
extension _IntClamp on int {
  int max(int other) => this > other ? this : other;
}