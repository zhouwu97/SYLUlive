import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/campus_availability_engine.dart';
import 'package:shenliyuan/models/campus_timeline.dart';

CampusTimelineItem _busy({
  required String title,
  required DateTime start,
  required DateTime end,
}) =>
    CampusTimelineItem(
      type: CampusTimelineType.course,
      title: title,
      startAt: start,
      endAt: end,
      allDay: false,
      location: '',
      sourceType: 'schedule',
      sourceId: title,
      importance: 'normal',
      editable: false,
    );

void main() {
  test('优先返回不与课程重叠的确定性时间段', () {
    final day = DateTime(2026, 9, 8);
    final result = const CampusAvailabilityEngine().findFreeTime(
      request: CampusAvailabilityRequest(
        range: DateTimeRange(
          start: DateTime(2026, 9, 8, 8),
          end: DateTime(2026, 9, 8, 22),
        ),
        duration: Duration(hours: 2),
        dayStart: TimeOfDay(hour: 8, minute: 0),
        dayEnd: TimeOfDay(hour: 22, minute: 0),
      ),
      busyItems: <CampusTimelineItem>[
        _busy(
          title: '高等数学',
          start: DateTime(2026, 9, 8, 10),
          end: DateTime(2026, 9, 8, 12),
        ),
      ],
    );

    expect(result.availableSlots, hasLength(1));
    expect(result.availableSlots.single.start, DateTime(2026, 9, 8, 8));
    expect(result.availableSlots.single.end, DateTime(2026, 9, 8, 10));
    expect(result.availableSlots.single.start.day, day.day);
  });

  test('重叠时返回冲突事实', () {
    final result = const CampusAvailabilityEngine().findFreeTime(
      request: CampusAvailabilityRequest(
        range: DateTimeRange(
          start: DateTime(2026, 9, 8, 18),
          end: DateTime(2026, 9, 8, 20),
        ),
        duration: Duration(hours: 2),
        dayStart: TimeOfDay(hour: 18, minute: 0),
        dayEnd: TimeOfDay(hour: 20, minute: 0),
      ),
      busyItems: <CampusTimelineItem>[
        _busy(
          title: '算法训练',
          start: DateTime(2026, 9, 8, 18),
          end: DateTime(2026, 9, 8, 20),
        ),
      ],
    );

    expect(result.availableSlots, isEmpty);
    expect(result.conflicts, hasLength(1));
    expect(result.conflicts.single.blockingItems.single.title, '算法训练');
  });
}
