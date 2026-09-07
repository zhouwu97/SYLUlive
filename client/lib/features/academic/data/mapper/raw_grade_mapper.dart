import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

/// 将学校教务协议中的原始成绩字段转换为主应用的统一成绩 JSON。
///
/// [RawGrade] 有意保留学校原始字段，不能直接交给 [EduGrade.fromJson]。
/// 该适配层集中维护协议字段到应用字段的映射，确保页面和加密缓存使用
/// 同一份 normalized 数据结构。
abstract final class RawGradeMapper {
  static Map<String, dynamic> toAppJson(RawGrade grade) {
    final raw = grade.raw;
    return <String, dynamic>{
      'name': _textOf(raw, const ['kcmc', 'name']),
      'course_id': _textOf(raw, const ['kch_id', 'course_id']),
      'course_code': _textOf(raw, const ['kch', 'course_code']),
      'class_id': _textOf(raw, const ['jxb_id', 'class_id']),
      'student_grade_id': _textOf(
        raw,
        const ['xh_id', 'student_grade_id'],
      ),
      'teacher': _textOf(raw, const ['jsxm', 'teacher']),
      'is_degree': _isDegree(raw),
      'credits': _valueOf(raw, const ['xf', 'credits']),
      'gpa': _valueOf(raw, const ['jd', 'gpa']),
      'grade_points': _valueOf(raw, const ['xfjd', 'grade_points']),
      'fraction': _valueOf(raw, const ['bfzcj', 'fraction']),
      'grade': _textOf(raw, const ['cj', 'grade']),
      'exam_type': _valueOf(raw, const ['ksxz', 'exam_type']),
      'course_category': _valueOf(raw, const ['kklxdm', 'course_category']),
      'assessment_method': _valueOf(raw, const ['khfsmc', 'assessment_method']),
    };
  }

  static Object? _valueOf(Map<String, Object?> raw, List<String> keys) {
    for (final key in keys) {
      if (raw.containsKey(key) && raw[key] != null) return raw[key];
    }
    return null;
  }

  static String _textOf(Map<String, Object?> raw, List<String> keys) =>
      _valueOf(raw, keys)?.toString().trim() ?? '';

  static bool _isDegree(Map<String, Object?> raw) {
    final legacyValue = _textOf(raw, const ['sfxwkc']);
    if (legacyValue.isNotEmpty) return legacyValue == '是';
    final value = _valueOf(raw, const ['is_degree']);
    return value == true || value == 1 || value == '1' || value == '是';
  }
}
