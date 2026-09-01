/// 学校页面或 JSON 响应与已审核 Schema 不一致。
///
/// 该异常是故意稳定、无敏感正文的错误边界。调用方不能把它转换为“暂无
/// 数据”，而应提示用户重新同步或等待 Parser 版本更新。
class SchemaMismatch implements Exception {
  const SchemaMismatch(this.message, {this.dataset, this.field});

  final String message;
  final String? dataset;
  final String? field;

  @override
  String toString() {
    final details = <String>[
      if (dataset != null && dataset!.trim().isNotEmpty) 'dataset=$dataset',
      if (field != null && field!.trim().isNotEmpty) 'field=$field',
    ];
    return details.isEmpty
        ? 'SchemaMismatch($message)'
        : 'SchemaMismatch(${details.join(',')}: $message)';
  }
}

/// 兼容调用方使用的异常名称。
typedef SchemaMismatchException = SchemaMismatch;
