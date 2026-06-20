class AppTime {
  const AppTime._();

  static const Duration _chinaOffset = Duration(hours: 8);

  /// Server timestamps are authoritative. Product-facing times use
  /// Asia/Shanghai so a misconfigured device timezone cannot shift them.
  static DateTime toShanghai(DateTime value) {
    return value.toUtc().add(_chinaOffset);
  }

  static DateTime nowShanghai() {
    return DateTime.now().toUtc().add(_chinaOffset);
  }
}
