import '../parser/week_parser.dart';

/// 教务接口原始课表记录。
///
/// 该模型故意不做合并或去重，保留服务器返回的每一条记录，避免不同周次、
/// 教室的分段课程在标准化前丢失。
final class RawCourse {
  const RawCourse({
    required this.name,
    required this.teacher,
    required this.location,
    required this.section,
    required this.weekDay,
    required this.weekExpression,
    this.periodOrder,
    this.periodLabel,
  });

  final String name;
  final String teacher;
  final String location;
  final String section;
  final String weekDay;
  final String weekExpression;

  /// Provider 的稳定排课序号。研究生课表的标签不是本科数字节次，
  /// 因此兼容层必须同时保留学校返回的序号和原始标签。
  final int? periodOrder;
  final String? periodLabel;

  /// Python/Dart 差分使用的稳定字段命名。
  Map<String, Object> toCanonicalJson() {
    final parsedWeeks = WeekParser.parse(weekExpression);
    final canonical = <String, Object>{
      'name': name,
      'teacher': teacher,
      'location': location,
      'section': section,
      'weekday': weekDay,
      'weekExpression': parsedWeeks.raw,
      'weeks': parsedWeeks.weeks.toList()..sort(),
    };
    if (periodOrder != null) canonical['periodOrder'] = periodOrder!;
    final label = periodLabel?.trim();
    if (label != null && label.isNotEmpty) canonical['periodLabel'] = label;
    return canonical;
  }
}
