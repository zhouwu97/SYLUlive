import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('onlyCache load ends immediately when no course cache exists', () async {
    final provider = CourseScheduleProvider()..setUserId('1001');

    await provider.loadCourses(onlyCache: true);

    expect(provider.isLoading, isFalse);
    expect(provider.courses, isEmpty);
    expect(provider.gridData, isEmpty);
  });

  test(
      'fetched courses are available from cache for the same user and semester',
      () async {
    final provider = CourseScheduleProvider()..setUserId('1001');

    await provider.applyFetchedCourses([
      {
        'name': '高等数学',
        'teacher': '王老师',
        'location': 'A101',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2, 3],
      },
    ]);

    final reloaded = CourseScheduleProvider()..setUserId('1001');
    final loaded = await reloaded.loadCachedCoursesIfAvailable();

    expect(loaded, isTrue);
    expect(reloaded.isLoading, isFalse);
    expect(reloaded.courses, hasLength(1));
    expect(reloaded.courses.single.name, '高等数学');
  });
}
