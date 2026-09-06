import 'grade_component.dart';

/// 成绩详情查询结果。
///
/// 对应 Python 端的 GradeDetailResponse。
final class GradeDetail {
  GradeDetail({
    required this.success,
    required this.courseName,
    required this.totalGrade,
    required Iterable<GradeComponent> components,
    this.message,
  }) : components = List.unmodifiable(components);

  /// 是否成功获取到成绩构成。
  final bool success;

  /// 课程名称。
  final String courseName;

  /// 总评成绩。
  ///
  /// 如果 components 中有"总"字分项，取其 score；
  /// 否则取最后一个分项的 score；
  /// 如果 components 为空，为空字符串。
  final String totalGrade;

  /// 成绩构成分项列表（不可变）。
  final List<GradeComponent> components;

  /// 失败时的提示消息。
  final String? message;

  Map<String, Object?> toJson() => {
        'success': success,
        'course_name': courseName,
        'total_grade': totalGrade,
        'components': components.map((c) => c.toJson()).toList(),
        'message': message,
      };

  @override
  String toString() =>
      'GradeDetail(success: $success, courseName: $courseName, '
      'totalGrade: $totalGrade, components: ${components.length}, message: $message)';
}
