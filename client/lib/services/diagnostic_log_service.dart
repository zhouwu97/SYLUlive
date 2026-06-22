import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/diagnostic_log_entry.dart';

class DiagnosticLogService {
  DiagnosticLogService._();
  static final DiagnosticLogService instance = DiagnosticLogService._();

  static const MethodChannel _channel = MethodChannel('shenliyuan/keep_alive');

  Future<List<DiagnosticLogEntry>> getLogs() async {
    final result =
        await _channel.invokeMethod<List<dynamic>>('getDiagnosticLogs');

    if (result == null) return const [];

    return result
        .whereType<Map<Object?, Object?>>()
        .map(DiagnosticLogEntry.fromMap)
        .toList();
  }

  Future<void> clearLogs() async {
    try {
      await _channel.invokeMethod('clearDiagnosticLogs');
    } catch (e) {
      // Ignore
    }
  }

  Future<void> recordError({
    required String source,
    required String type,
    required String summary,
    required String detail,
  }) async {
    try {
      await _channel.invokeMethod('writeDiagnosticLog', {
        'level': 'error',
        'source': source,
        'type': type,
        'summary': summary,
        'detail': detail,
      });
    } catch (e) {
      // Ignore
      debugPrint('写入诊断日志失败: $e');
    }
  }
}
