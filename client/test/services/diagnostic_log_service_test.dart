import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/diagnostic_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shenliyuan/keep_alive');
  const pushChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pushChannel, null);
  });

  test('写入诊断事件时向原生传递结构化上下文', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return true;
    });

    await DiagnosticLogService.instance.record(
      level: 'error',
      source: '设备工具',
      type: '设备任务请求失败',
      summary: '拉取待处理任务失败',
      detail: '连接超时',
      eventCode: 'device_job_request_failed',
      category: 'device',
      operation: 'pending',
      result: 'failure',
      traceId: 'trace-1',
      durationMs: 1200,
      httpStatus: 502,
      retryCount: 2,
      route: '/device/jobs/pending',
      metadata: const <String, Object?>{
        'dioType': 'connectionTimeout',
      },
    );

    expect(captured?.method, 'writeDiagnosticLog');
    expect(captured?.arguments,
        containsPair('eventCode', 'device_job_request_failed'));
    expect(captured?.arguments, containsPair('operation', 'pending'));
    expect(captured?.arguments, containsPair('httpStatus', 502));
    expect(
      captured?.arguments,
      containsPair('metadata', <String, Object?>{
        'dioType': 'connectionTimeout',
      }),
    );
  });

  test('运行状态只读汇总保活和推送诊断', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getKeepAliveStatus');
      return <String, Object?>{
        'enabled': true,
        'serviceRunning': true,
        'hideRecentsEnabled': false,
      };
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pushChannel, (call) async {
      expect(call.method, 'getPushDiagnostics');
      return <String, Object?>{
        'pushEnabled': true,
        'registrationId': 'present',
        'notificationsEnabled': true,
        'privateMessageChannelBlocked': false,
        'storedAliasState': 'bound',
      };
    });

    final status = await DiagnosticLogService.instance.getRuntimeStatus();

    expect(status.keepAliveRunning, isTrue);
    expect(status.pushEnabled, isTrue);
    expect(status.pushConnected, isTrue);
    expect(status.aliasState, 'bound');
  });
}
