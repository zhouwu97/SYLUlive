import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/campus_timeline.dart';
import 'package:shenliyuan/models/exam_schedule.dart';
import 'package:shenliyuan/models/user_calendar.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/services/unified_timeline_service.dart';

void main() {
  test('聚合课程、考试、竞赛和个人日历为统一时间线', () {
    final range = DateTimeRange(
      start: DateTime(2026, 9, 7),
      end: DateTime(2026, 9, 14),
    );
    final items = const UnifiedTimelineService().build(
      range: range,
      semesterStart: DateTime(2026, 9, 7),
      courses: <CourseBlock>[
        CourseBlock(
          id: 1,
          courseCode: 'MATH',
          name: '高等数学',
          color: '#147C72',
          weekday: 1,
          startSection: 1,
          endSection: 2,
          weeks: <int>[1],
        ),
      ],
      exams: <ExamModel>[
        ExamModel(
          name: '英语考试',
          startTime: DateTime(2026, 9, 9, 14),
          endTime: DateTime(2026, 9, 9, 16),
          location: '教学楼 A',
        ),
      ],
      competitions: <CompetitionTimelineEntry>[
        CompetitionTimelineEntry(
          eventId: 123,
          title: '蓝桥杯',
          registrationEnd: DateTime(2026, 9, 12, 23, 59),
          version: 5,
        ),
      ],
      personalEvents: <UserCalendarEvent>[
        UserCalendarEvent(
          id: 8,
          calendarId: 1,
          title: '算法训练',
          description: '',
          startAt: DateTime.utc(2026, 9, 10, 11),
          endAt: DateTime.utc(2026, 9, 10, 13),
          allDay: false,
          location: '',
          timezone: 'Asia/Shanghai',
          sourceType: 'manual',
          createdBy: 'user',
          version: 1,
        ),
      ],
    );

    expect(
        items.map((item) => item.type),
        containsAll(<CampusTimelineType>[
          CampusTimelineType.course,
          CampusTimelineType.exam,
          CampusTimelineType.competition,
          CampusTimelineType.personal,
        ]));
    final competition = items.firstWhere(
      (item) => item.type == CampusTimelineType.competition,
    );
    expect(competition.sourceVersion, '5');
    expect(competition.editable, isFalse);
  });
}
