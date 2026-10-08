// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Calendar-day helpers shared by the attempt rows (route detail) and the
/// month-grouped History list (§24).
library;

/// How many calendar days separate [from] and [to].
///
/// The comparison reads each input's own year/month/day fields and rebuilds
/// them as UTC dates before subtracting. That matters because a calendar day is
/// not always 24 hours long: across a daylight-saving transition the elapsed
/// time between two consecutive *local* midnights is 23 or 25 hours, and
/// [Duration.inDays] on that span would truncate to the wrong whole number —
/// giving "Today" for a date that is clearly yesterday. In UTC every day is
/// 24 hours, so the result depends only on the two calendar dates, never on the
/// machine's timezone or on a transition falling between them.
int calendarDayDifference(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;

/// Renders an attempt timestamp as a relative-or-absolute label.
///
/// [now] is injectable so the behaviour can be unit-tested instead of being
/// pinned to the wall clock — the seeded history sits a fixed 26 hours in the
/// past, so its label legitimately flips between "Yesterday" and an absolute
/// date depending on the time of day.
String dateLabelFor(DateTime d, {DateTime? now}) {
  final diff = calendarDayDifference(d, now ?? DateTime.now());
  if (diff == 0) {
    return 'Today';
  }
  if (diff == 1) {
    return 'Yesterday';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
