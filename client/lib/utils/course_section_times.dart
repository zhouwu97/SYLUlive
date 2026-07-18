/// 沈阳理工大学课程节次时间表。
///
/// 课程卡片和实况窗必须共用同一份时间定义，避免系统触达与课表页面显示不一致。
class CourseSectionTimes {
  CourseSectionTimes._();

  static const List<String> starts = [
    '08:00',
    '08:55',
    '10:00',
    '10:55',
    '13:00',
    '13:55',
    '14:50',
    '15:45',
    '16:40',
    '17:35',
    '18:30',
    '19:25',
  ];

  static const List<String> ends = [
    '08:45',
    '09:40',
    '10:45',
    '11:40',
    '13:45',
    '14:40',
    '15:35',
    '16:30',
    '17:25',
    '18:20',
    '19:15',
    '20:10',
  ];

  static String startLabel(int section) => starts[_index(section)];

  static String endLabel(int section) => ends[_index(section)];

  static DateTime startAt(DateTime date, int section) =>
      _at(date, startLabel(section));

  static DateTime endAt(DateTime date, int section) =>
      _at(date, endLabel(section));

  static int _index(int section) => (section - 1).clamp(0, starts.length - 1);

  static DateTime _at(DateTime date, String value) {
    final parts = value.split(':');
    return DateTime(
      date.year,
      date.month,
      date.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }
}
