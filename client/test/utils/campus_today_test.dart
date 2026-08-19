import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_schedule.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/utils/campus_today.dart';

CourseBlock _course({
  required int id,
  required int weekday,
  required int startSection,
  required int endSection,
  String name = '课程',
}) {
  return CourseBlock(
    id: id,
    courseCode: 'C$id',
    name: name,
    color: '#6366F1',
    weekday: weekday,
    startSection: startSection,
    endSection: endSection,
    weeks: const [],
  );
}

void main() {
  final now = DateTime(2026, 8, 10, 10, 15);

  test('正在上课优先于稍后课程，且结束后不再显示旧课', () {
    final entries = buildCampusTodayEntries(
      now: now,
      courses: [
        _course(id: 1, weekday: now.weekday, startSection: 1, endSection: 1),
        _course(
          id: 2,
          weekday: now.weekday,
          startSection: 3,
          endSection: 3,
          name: '高等数学',
        ),
        _course(
          id: 3,
          weekday: now.weekday,
          startSection: 4,
          endSection: 4,
          name: '英语',
        ),
      ],
      exams: const [],
    );

    expect(entries, hasLength(1));
    expect(entries.single.title, '正在上课 · 高等数学');
    expect(entries.single.courseState, CampusTodayCourseState.active);
  });

  test('课程结束后选择下一节，而当天无剩余课程时隐藏课程项', () {
    final upcoming = buildCampusTodayEntries(
      now: DateTime(2026, 8, 10, 10, 50),
      courses: [
        _course(
          id: 1,
          weekday: 1,
          startSection: 3,
          endSection: 3,
          name: '高等数学',
        ),
        _course(
          id: 2,
          weekday: 1,
          startSection: 4,
          endSection: 4,
          name: '英语',
        ),
      ],
      exams: const [],
    );
    expect(upcoming.single.title, '下一节课 · 英语');
    expect(upcoming.single.courseState, CampusTodayCourseState.upcoming);

    final ended = buildCampusTodayEntries(
      now: DateTime(2026, 8, 10, 21),
      courses: [
        _course(id: 1, weekday: 1, startSection: 12, endSection: 12),
      ],
      exams: const [],
    );
    expect(ended, isEmpty);
  });

  test('考试进行中仍保留，结束后切换到下一场', () {
    final current = ExamModel(
      name: '进行中的考试',
      startTime: now.subtract(const Duration(minutes: 20)),
      endTime: now.add(const Duration(minutes: 40)),
      location: 'A101',
    );
    final next = ExamModel(
      name: '下一场考试',
      startTime: now.add(const Duration(days: 1)),
      endTime: now.add(const Duration(days: 1, hours: 2)),
      location: 'B202',
    );
    final entries = buildCampusTodayEntries(
      now: now,
      courses: const [],
      exams: [current, next],
    );

    expect(entries.single.title, '考试 · 进行中的考试');
    expect(entries.single.subtitle, contains('进行中'));
    expect(entries.single.subtitle, contains('A101'));
  });
}
