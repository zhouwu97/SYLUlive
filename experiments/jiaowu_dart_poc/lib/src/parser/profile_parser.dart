import 'package:html/parser.dart' as html_parser;

import '../error/jiaowu_exception.dart';
import '../model/student_profile.dart';

/// 学生信息页面的 HTML 解析器。原始字段只在这里映射到稳定模型。
abstract final class ProfileParser {
  static StudentProfile parse(String body) {
    final document = html_parser.parse(body);
    final studentId = _studentId(document);
    if (studentId == null) {
      throw const ProtocolChangedException(
        message: '学生信息页面缺少一致的学校学号字段，无法通过身份匹配',
      );
    }
    final profile = StudentProfile(
      name: _field(document, 'col_xm'),
      grade: _field(document, 'col_njdm_id'),
      college: _field(document, 'col_jg_id'),
      major: _field(document, 'col_zyh_id'),
      studentId: studentId,
    );
    if (!hasAnyFields(body)) {
      throw const ProtocolChangedException(
        message: '学生信息页面缺少教务字段，页面结构可能已变化',
      );
    }
    return profile;
  }

  static bool hasAnyFields(String body) {
    final document = html_parser.parse(body);
    return const [
      'col_xm',
      'col_njdm_id',
      'col_jg_id',
      'col_zyh_id',
    ].any((id) => _field(document, id).isNotEmpty);
  }

  static String _field(dynamic document, String id) {
    final element = document.querySelector('#$id');
    if (element == null) return '';
    final paragraph = element.querySelector('p');
    return (paragraph ?? element).text.trim();
  }

  static String? _studentId(dynamic document) {
    // 不从登录请求参数或本机 Session 推导身份，只接受学校资料页的三处
    // 明确字段，三者必须同时存在且完全一致。
    final profileValue = _field(document, 'col_xh');
    final hiddenValue = _inputValue(document, 'xh_id');
    final currentValue = _inputValue(document, 'curXh_id');
    if (profileValue.isEmpty || hiddenValue.isEmpty || currentValue.isEmpty) {
      return null;
    }
    if (profileValue != hiddenValue || profileValue != currentValue) {
      return null;
    }
    return profileValue;
  }

  static String _inputValue(dynamic document, String id) {
    final input = document.querySelector('#$id');
    return input?.attributes['value']?.trim() ?? '';
  }
}
