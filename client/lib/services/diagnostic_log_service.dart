import 'package:flutter/services.dart';
import '../models/diagnostic_log_entry.dart';

class DiagnosticLogService {
  DiagnosticLogService._();
  static final DiagnosticLogService instance = DiagnosticLogService._();

  static const MethodChannel _channel = MethodChannel('shenliyuan/keep_alive');

  Future<List<DiagnosticLogEntry>> getLogs() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getDiagnosticLogs');
      if (result == null) return [];
      
      return result
          .map((item) => item as Map<Object?, Object?>)
          .map((map) => DiagnosticLogEntry.fromMap(map))
          .toList();
    } catch (e) {
      return [];
    }
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
    }
  }
}
