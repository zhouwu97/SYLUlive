import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/diagnostic_log_entry.dart';

void main() {
  test('结构化诊断字段可解析且旧日志保持兼容', () {
    final entry = DiagnosticLogEntry.fromMap(<Object?, Object?>{
      'id': 'log-1',
      'timestamp': 1000,
      'elapsedRealtime': 200,
      'level': 'error',
      'source': '设备工具',
      'type': '设备任务请求失败',
      'summary': '拉取待处理任务时服务器请求失败',
      'detail': '连接超时',
      'sessionId': 'session-1',
      'pid': 42,
      'appVersion': '1.0.0',
      'manufacturer': 'Test',
      'model': 'Device',
      'sdkInt': 34,
      'repeatCount': 3,
      'firstSeenAt': 900,
      'lastSeenAt': 1100,
      'eventCode': 'device_job_request_failed',
      'category': 'device',
      'operation': 'pending',
      'result': 'failure',
      'traceId': 'trace-1',
      'durationMs': 1250,
      'httpStatus': 502,
      'retryCount': 2,
      'route': '/device/jobs/pending',
      'taskId': 7,
      'isForeground': true,
      'metadata': <Object?, Object?>{
        'dioType': 'connectionTimeout',
        'retryable': true,
      },
    });

    expect(entry.eventCode, 'device_job_request_failed');
    expect(entry.category, 'device');
    expect(entry.operation, 'pending');
    expect(entry.result, 'failure');
    expect(entry.traceId, 'trace-1');
    expect(entry.durationMs, 1250);
    expect(entry.httpStatus, 502);
    expect(entry.retryCount, 2);
    expect(entry.route, '/device/jobs/pending');
    expect(entry.taskId, 7);
    expect(entry.isForeground, isTrue);
    expect(entry.metadata, <String, Object?>{
      'dioType': 'connectionTimeout',
      'retryable': true,
    });

    final legacy = DiagnosticLogEntry.fromMap(<Object?, Object?>{
      'id': 'legacy',
      'timestamp': 1,
    });
    expect(legacy.eventCode, isEmpty);
    expect(legacy.category, 'app');
    expect(legacy.metadata, isEmpty);
  });
}
