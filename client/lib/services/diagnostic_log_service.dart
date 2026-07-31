import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/diagnostic_log_entry.dart';

class DiagnosticLogService {
  DiagnosticLogService._();
  static final DiagnosticLogService instance = DiagnosticLogService._();

  static const MethodChannel _channel = MethodChannel('shenliyuan/keep_alive');
  static const MethodChannel _pushChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );

  Future<List<DiagnosticLogEntry>> getLogs() async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'getDiagnosticLogs',
    );

    if (result == null) return const [];

    return result
        .whereType<Map<Object?, Object?>>()
        .map(DiagnosticLogEntry.fromMap)
        .toList();
  }

  Future<void> clearLogs() async {
    await _channel.invokeMethod('clearDiagnosticLogs');
  }

  Future<DiagnosticRuntimeStatus> getRuntimeStatus() async {
    Map<Object?, Object?>? keepAlive;
    Map<Object?, Object?>? push;
    try {
      keepAlive = await _channel.invokeMapMethod<Object?, Object?>(
        'getKeepAliveStatus',
      );
    } catch (_) {}
    try {
      push = await _pushChannel.invokeMapMethod<Object?, Object?>(
        'getPushDiagnostics',
      );
    } catch (_) {}
    return DiagnosticRuntimeStatus.fromMaps(
      keepAlive: keepAlive,
      push: push,
    );
  }

  Future<void> record({
    required String level,
    required String source,
    required String type,
    required String summary,
    required String detail,
    String eventCode = '',
    String category = 'app',
    String operation = '',
    String result = '',
    String traceId = '',
    int? durationMs,
    int? httpStatus,
    int retryCount = 0,
    String route = '',
    int? taskId,
    bool? isForeground,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    try {
      await _channel.invokeMethod('writeDiagnosticLog', {
        'level': level,
        'source': source,
        'type': type,
        'summary': summary,
        'detail': detail,
        'eventCode': eventCode,
        'category': category,
        'operation': operation,
        'result': result,
        'traceId': traceId,
        'durationMs': durationMs,
        'httpStatus': httpStatus,
        'retryCount': retryCount,
        'route': route,
        'taskId': taskId,
        'isForeground': isForeground,
        'metadata': metadata,
      });
    } catch (e) {
      debugPrint('写入诊断日志失败: $e');
    }
  }

  Future<void> recordError({
    required String source,
    required String type,
    required String summary,
    required String detail,
    String eventCode = '',
    String category = 'app',
    String operation = '',
    String result = 'failure',
    String traceId = '',
    int? durationMs,
    int? httpStatus,
    int retryCount = 0,
    String route = '',
    int? taskId,
    bool? isForeground,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    return record(
      level: 'error',
      source: source,
      type: type,
      summary: summary,
      detail: detail,
      eventCode: eventCode,
      category: category,
      operation: operation,
      result: result,
      traceId: traceId,
      durationMs: durationMs,
      httpStatus: httpStatus,
      retryCount: retryCount,
      route: route,
      taskId: taskId,
      isForeground: isForeground,
      metadata: metadata,
    );
  }
}

class DiagnosticRuntimeStatus {
  const DiagnosticRuntimeStatus({
    this.keepAliveEnabled,
    this.keepAliveRunning,
    this.hideRecentsEnabled,
    this.pushEnabled,
    this.pushConnected,
    this.notificationsEnabled,
    this.privateMessageChannelBlocked,
    this.aliasState,
  });

  final bool? keepAliveEnabled;
  final bool? keepAliveRunning;
  final bool? hideRecentsEnabled;
  final bool? pushEnabled;
  final bool? pushConnected;
  final bool? notificationsEnabled;
  final bool? privateMessageChannelBlocked;
  final String? aliasState;

  factory DiagnosticRuntimeStatus.fromMaps({
    required Map<Object?, Object?>? keepAlive,
    required Map<Object?, Object?>? push,
  }) {
    return DiagnosticRuntimeStatus(
      keepAliveEnabled: keepAlive?['enabled'] as bool?,
      keepAliveRunning: keepAlive?['serviceRunning'] as bool?,
      hideRecentsEnabled: keepAlive?['hideRecentsEnabled'] as bool?,
      pushEnabled: push?['pushEnabled'] as bool?,
      pushConnected: push == null
          ? null
          : (push['registrationId']?.toString().isNotEmpty ?? false),
      notificationsEnabled: push?['notificationsEnabled'] as bool?,
      privateMessageChannelBlocked:
          push?['privateMessageChannelBlocked'] as bool?,
      aliasState: push?['storedAliasState']?.toString(),
    );
  }
}
