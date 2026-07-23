import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/exam_schedule_repository.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取考试页导入的本地考试安排', () async {
    AppPreferencesStore.setMockInitialValues({
      'local_exams': jsonEncode([
        {
          'name': '高等数学',
          'startTime': '2026-07-15T09:00:00.000',
          'endTime': '2026-07-15T11:00:00.000',
          'location': '教学楼 A101',
          'semester': '2025-2026-02',
        },
      ]),
    });

    final exams = await ExamScheduleRepository().load();

    expect(exams, hasLength(1));
    expect(exams.single.name, '高等数学');
    expect(exams.single.startTime, DateTime(2026, 7, 15, 9));
    expect(exams.single.occursOn(DateTime(2026, 7, 15)), isTrue);
    expect(exams.single.occursOn(DateTime(2026, 7, 16)), isFalse);
  });
}
