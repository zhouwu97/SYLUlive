/// 教务学年/学期请求的公共边界校验。
abstract final class JiaowuRequestValidator {
  static void validateAcademicRequest({
    required String year,
    required int semester,
  }) {
    if (!RegExp(r'^\d{4}$').hasMatch(year)) {
      throw ArgumentError.value(year, 'year', '学年必须是四位数字');
    }
    if (semester != 3 && semester != 12) {
      throw ArgumentError.value(semester, 'semester', '仅支持学期编码 3 或 12');
    }
  }
}
