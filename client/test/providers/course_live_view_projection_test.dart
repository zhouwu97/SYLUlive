import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('课表只投影正在进行或 60 分钟内开始的下一节课', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = CourseScheduleProvider()..setUserId('1001');
    await provider.applyFetchedCourses([
      {
        'id': 1001,
        'course_code': 'MATH-1',
        'name': '高等数学',
        'location': '文体中心203',
        'weekday': 5,
        'start_section': 1,
        'end_section': 2,
        'weeks': <int>[],
      },
    ]);

    expect(
      provider.resolveCourseLiveView(DateTime(2026, 7, 17, 6, 59)),
      isNull,
    );

    final upcoming =
        provider.resolveCourseLiveView(DateTime(2026, 7, 17, 7, 0));
    expect(upcoming, isNotNull);
    expect(upcoming!.title, '高等数学');
    expect(upcoming.startTime, DateTime(2026, 7, 17, 8));
    expect(upcoming.endTime, DateTime(2026, 7, 17, 9, 40));
    expect(upcoming.businessId, startsWith('${provider.currentTerm.id}_'));
    expect(upcoming.businessId, endsWith('_20260717_1'));

    expect(
      provider.resolveCourseLiveView(DateTime(2026, 7, 17, 9, 41)),
      isNull,
    );
  });
}
