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
  });

  final String name;
  final String teacher;
  final String location;
  final String section;
  final String weekDay;
  final String weekExpression;

  /// Python/Dart 差分使用的稳定字段命名。
  Map<String, String> toCanonicalJson() => {
        'name': name,
        'teacher': teacher,
        'location': location,
        'section': section,
        'weekday': weekDay,
        'weeks': weekExpression,
      };
}
