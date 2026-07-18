import 'dart:convert';

const competitionImportMaxBytes = 2 * 1024 * 1024;

/// 解析竞赛计划导入数据，并统一校验服务端要求的顶层结构。
Map<String, dynamic> decodeCompetitionImportPayload(String source) {
  final text = source.trim();
  if (text.isEmpty) {
    throw const FormatException('JSON 内容不能为空');
  }
  if (utf8.encode(text).length > competitionImportMaxBytes) {
    throw const FormatException('JSON 内容不能超过 2 MB');
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('JSON 格式不正确，请检查逗号、引号和括号');
  }
  if (decoded is! Map || decoded['events'] is! List) {
    throw const FormatException('JSON 顶层必须是 {"events": [...]}');
  }

  return Map<String, dynamic>.from(decoded);
}
