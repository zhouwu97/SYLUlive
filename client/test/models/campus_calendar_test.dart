import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/campus_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calendar = CampusCalendar.fromJson({
    'schema_version': 1,
    'calendar_id': 'test-calendar',
    'school': '测试大学',
    'academic_year': '2026-2027',
    'timezone': 'Asia/Shanghai',
    'version': 1,
    'status': 'published',
    'source': const {
      'type': 'official_calendar_image',
      'title': '测试校历',
      'file_name': 'source.jpg',
      'verified': true,
    },
    'semesters': [
      {
        'id': 'fall',
        'name': '第一学期',
        'start_date': '2026-09-01',
        'end_date': '2026-09-30',
        'teaching_weeks': [
          {'week': 1, 'start_date': '2026-09-01', 'end_date': '2026-09-06'},
          {'week': 2, 'start_date': '2026-09-07', 'end_date': '2026-09-13'},
        ],
      },
    ],
    'events': [
      {
        'id': 'holiday',
        'title': '校庆假期',
        'type': 'holiday',
        'start_date': '2026-09-10',
        'end_date': '2026-09-11',
        'badge': '休',
        'description': '学校明确安排的假期。',
        'status': 'confirmed',
      },
    ],
    'day_overrides': [
      {
        'date': '2026-09-12',
        'day_mode': 'makeup_teaching',
        'badge': '课',
        'title': '调休补课',
        'schedule_as_weekday': 3,
        'description': '按星期三课程安排执行。',
      },
    ],
    'unresolved_items': const [],
  });

  test('教学周按明确日期范围查询，不按学期起点推算', () {
    expect(calendar.dayInfo(DateTime(2026, 9, 8)).teachingWeek?.week, 2);
    expect(calendar.dayInfo(DateTime(2026, 9, 20)).teachingWeek, isNull);
  });

  test('调休补课覆盖周末默认状态，并保留当天事件', () {
    final info = calendar.dayInfo(DateTime(2026, 9, 12));

    expect(info.isWeekend, isTrue);
    expect(info.isTeachingDay, isTrue);
    expect(info.override?.badge, '课');
    expect(info.markers.single.badge, '课');
  });

  test('连续假期在范围内每天都显示事件标记', () {
    final info = calendar.dayInfo(DateTime(2026, 9, 11));

    expect(info.events.single.title, '校庆假期');
    expect(info.markers.single.badge, '休');
  });

  test('内置回退校历可读取，并包含官方原图中的寒暑假范围', () async {
    final raw = await rootBundle.loadString(
      'assets/data/campus_calendar_fallback.json',
    );
    final fallback = CampusCalendar.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );

    expect(fallback.semesters, hasLength(2));
    expect(fallback.dayInfo(DateTime(2027, 1, 11)).markers.single.badge, '假');
    expect(fallback.dayInfo(DateTime(2027, 8, 23)).markers.single.badge, '始');
  });
}
