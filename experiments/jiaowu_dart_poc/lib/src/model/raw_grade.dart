/// 教务成绩接口返回的一条原始记录。
///
/// 先完整保留服务器字段，避免在协议尚未稳定前过早固化业务成绩模型。
final class RawGrade {
  RawGrade({required Map<String, Object?> raw}) : raw = _freezeMap(raw);

  final Map<String, Object?> raw;

  /// 生成不包含账号身份字段的稳定 JSON 视图，供 CLI 和跨语言差分使用。
  Map<String, Object?> toCanonicalJson() => _canonicalMap(_redact(raw));

  static Map<String, Object?> _redact(Map<String, Object?> source) {
    return {
      for (final entry in source.entries)
        if (!_isSensitiveKey(entry.key)) entry.key: _redactValue(entry.value),
    };
  }

  static Object? _redactValue(Object? value) {
    if (value is Map<String, Object?>) return _redact(value);
    if (value is List<Object?>) {
      return value.map(_redactValue).toList(growable: false);
    }
    return value;
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key.toLowerCase();
    const exact = {
      'xh',
      'xh_id',
      'xsxh',
      'xsid',
      'sfzh',
      'xsxm',
      'xm_xs',
      'xsmc',
      'xm',
      // 成绩接口中的这些字段可能直接包含学号、班号或复合身份键。
      'bh',
      'bh_id',
      'bj',
      'key',
      'student_id',
      'user_id',
    };
    return exact.contains(normalized) ||
        normalized.contains('cookie') ||
        normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('csrf');
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) {
  return Map.unmodifiable({
    for (final entry in source.entries) entry.key: _freezeValue(entry.value),
  });
}

Object? _freezeValue(Object? value) {
  if (value is Map<String, Object?>) return _freezeMap(value);
  if (value is List<Object?>) {
    return List.unmodifiable(value.map(_freezeValue));
  }
  return value;
}

Map<String, Object?> _canonicalMap(Map<String, Object?> source) {
  final keys = source.keys.toList()..sort();
  return {
    for (final key in keys) key: _canonicalValue(source[key]),
  };
}

Object? _canonicalValue(Object? value) {
  if (value is Map<String, Object?>) return _canonicalMap(value);
  if (value is List<Object?>) {
    return value.map(_canonicalValue).toList(growable: false);
  }
  return value;
}
