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
      'name': _text(raw['kcmc']),
      'course_id': _text(raw['kch_id']),
      'course_code': _text(raw['kch']),
      'class_id': _text(raw['jxb_id']),
      'student_grade_id': _text(raw['xh_id']),
      'teacher': _text(raw['jsxm']),
      'is_degree': _text(raw['sfxwkc']) == '是',
      'credits': raw['xf'],
      'gpa': raw['jd'],
      'grade_points': raw['xfjd'],
      'fraction': raw['bfzcj'],
      'grade': _text(raw['cj']),
      'exam_type': raw['ksxz'],
      'course_category': raw['kklxdm'],
      'assessment_method': raw['khfsmc'],
    };
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';
}
