import 'package:flutter/material.dart';

import '../../../models/campus_timeline.dart';

class CampusAvailabilityRequest {
  const CampusAvailabilityRequest({
    required this.range,
    required this.duration,
    this.requiredSlots = 1,
    this.dayStart = const TimeOfDay(hour: 8, minute: 0),
    this.dayEnd = const TimeOfDay(hour: 22, minute: 0),
    this.weekdays = const <int>{1, 2, 3, 4, 5, 6, 7},
  });

  final DateTimeRange range;
  final Duration duration;
  final int requiredSlots;
  final TimeOfDay dayStart;
  final TimeOfDay dayEnd;
  final Set<int> weekdays;
}

class CampusAvailableSlot {
  const CampusAvailableSlot({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
}

class CampusTimelineConflict {
  const CampusTimelineConflict({
    required this.slot,
    required this.blockingItems,
  });

  final CampusAvailableSlot slot;
  final List<CampusTimelineItem> blockingItems;
}

class CampusAvailabilityResult {
  const CampusAvailabilityResult({
    required this.availableSlots,
    required this.conflicts,
  });

  final List<CampusAvailableSlot> availableSlots;
  final List<CampusTimelineConflict> conflicts;

  bool get hasEnoughSlots => availableSlots.isNotEmpty;
}

/// 时间计算只看结构化 Timeline，不依赖 LLM 对日期做推理。
class CampusAvailabilityEngine {
  const CampusAvailabilityEngine();

  CampusAvailabilityResult findFreeTime({
    required CampusAvailabilityRequest request,
    required List<CampusTimelineItem> busyItems,
  }) {
    if (request.duration <= Duration.zero || request.requiredSlots <= 0) {
      return const CampusAvailabilityResult(
        availableSlots: <CampusAvailableSlot>[],
        conflicts: <CampusTimelineConflict>[],
      );
    }
    final available = <CampusAvailableSlot>[];
    final conflicts = <CampusTimelineConflict>[];
    var day = _dayStart(request.range.start);
    final lastDay = _dayStart(request.range.end);
    while (!day.isAfter(lastDay) && available.length < request.requiredSlots) {
      if (request.weekdays.contains(day.weekday)) {
        final windowStart = _at(day, request.dayStart);
        final windowEnd = _at(day, request.dayEnd);
        final start = windowStart.isAfter(request.range.start)
            ? windowStart
            : request.range.start;
        final end = windowEnd.isBefore(request.range.end)
            ? windowEnd
            : request.range.end;
        _scanDay(
          start: start,
          end: end,
          duration: request.duration,
          busyItems: busyItems,
          available: available,
          conflicts: conflicts,
          remaining: request.requiredSlots - available.length,
        );
      }
      day = day.add(const Duration(days: 1));
    }
    return CampusAvailabilityResult(
      availableSlots: List.unmodifiable(available),
      conflicts: List.unmodifiable(conflicts),
    );
  }

  bool hasConflict({
    required DateTimeRange slot,
    required List<CampusTimelineItem> busyItems,
  }) =>
      busyItems.any((item) => item.intersects(slot));

  CampusLoadSummary calculateLoad({
    required DateTimeRange range,
    required List<CampusTimelineItem> items,
  }) {
    final visible = items.where((item) => item.intersects(range));
    var occupiedMinutes = 0;
    var deadlineCount = 0;
    for (final item in visible) {
      occupiedMinutes += item.endAt.difference(item.startAt).inMinutes;
      if (item.type == CampusTimelineType.competition &&
          item.title.contains('截止')) {
        deadlineCount++;
      }
    }
    final dayCount = range.end.difference(range.start).inDays.clamp(1, 366);
    return CampusLoadSummary(
      occupiedMinutes: occupiedMinutes,
      deadlineCount: deadlineCount,
      averageDailyMinutes: occupiedMinutes / dayCount,
      itemCount: visible.length,
    );
  }

  void _scanDay({
    required DateTime start,
    required DateTime end,
    required Duration duration,
    required List<CampusTimelineItem> busyItems,
    required List<CampusAvailableSlot> available,
    required List<CampusTimelineConflict> conflicts,
    required int remaining,
  }) {
    if (!end.isAfter(start)) return;
    final dayAvailableBefore = available.length;
    final dayBusy = busyItems
        .where((item) => item.intersects(DateTimeRange(start: start, end: end)))
        .toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    var cursor = start;
    for (final busy in dayBusy) {
      final busyStart = busy.startAt.isAfter(start) ? busy.startAt : start;
      if (busyStart.difference(cursor) >= duration) {
        available.add(CampusAvailableSlot(
          start: cursor,
          end: cursor.add(duration),
        ));
        if (available.length >= remaining) return;
      }
      if (busy.endAt.isAfter(cursor)) cursor = busy.endAt;
      if (!cursor.isBefore(end)) {
        if (available.length == dayAvailableBefore) {
          conflicts.add(CampusTimelineConflict(
            slot: CampusAvailableSlot(start: start, end: end),
            blockingItems: List.unmodifiable(dayBusy),
          ));
        }
        return;
      }
    }
    if (end.difference(cursor) >= duration) {
      available
          .add(CampusAvailableSlot(start: cursor, end: cursor.add(duration)));
    } else if (dayBusy.isNotEmpty && available.length == dayAvailableBefore) {
      conflicts.add(CampusTimelineConflict(
        slot: CampusAvailableSlot(start: start, end: end),
        blockingItems: List.unmodifiable(dayBusy),
      ));
    }
  }

  static DateTime _dayStart(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime _at(DateTime day, TimeOfDay time) =>
      DateTime(day.year, day.month, day.day, time.hour, time.minute);
}

class CampusLoadSummary {
  const CampusLoadSummary({
    required this.occupiedMinutes,
    required this.deadlineCount,
    required this.averageDailyMinutes,
    required this.itemCount,
  });

  final int occupiedMinutes;
  final int deadlineCount;
  final double averageDailyMinutes;
  final int itemCount;
}
