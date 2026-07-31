import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/diagnostic_log_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shenliyuan/keep_alive');
  const pushChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );

  testWidgets('诊断中心在窄屏展示概览、筛选和结构化事件', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now().millisecondsSinceEpoch;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getDiagnosticLogs') {
        return <Map<String, Object?>>[
          <String, Object?>{
            'id': 'log-1',
            'timestamp': now,
            'lastSeenAt': now,
            'firstSeenAt': now,
            'level': 'error',
            'source': '设备工具',
            'type': '设备任务请求失败',
            'summary': '拉取待处理任务时服务器请求失败',
            'detail': '连接超时',
            'eventCode': 'device_job_request_failed',
            'category': 'device',
            'operation': 'pending',
            'result': 'failure',
            'httpStatus': 502,
            'repeatCount': 3,
          },
        ];
      }
      if (call.method == 'getKeepAliveStatus') {
        return <String, Object?>{
          'enabled': true,
          'serviceRunning': true,
          'hideRecentsEnabled': true,
        };
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pushChannel, (_) async {
      return <String, Object?>{
        'pushEnabled': true,
        'registrationId': 'present',
        'notificationsEnabled': true,
        'privateMessageChannelBlocked': false,
        'storedAliasState': 'bound',
      };
    });
    addTearDown(
      () {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pushChannel, null);
      },
    );

    await tester.pumpWidget(
      const MaterialApp(home: DiagnosticLogScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('诊断中心'), findsOneWidget);
    expect(find.text('当前状态：存在 1 项需关注'), findsOneWidget);
    expect(find.text('设备任务请求失败'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
