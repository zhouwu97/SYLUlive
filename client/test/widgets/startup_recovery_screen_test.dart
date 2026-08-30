import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/startup_recovery_screen.dart';

void main() {
  testWidgets('启动恢复应用根节点提供方向性和 Material 环境', (tester) async {
    await tester.pumpWidget(
      const StartupRecoveryApp(child: StartupRecoveryScreen()),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('正在准备应用'), findsOneWidget);
  });

  testWidgets('启动失败时显示用户级恢复入口', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupRecoveryScreen(
          error: StateError('hive failed'),
          diagnosticText: 'diagnostic-id',
          onRetry: () async {
            retried = true;
          },
          onClearNonSensitiveCache: () async {},
        ),
      ),
    );

    expect(find.text('应用启动失败'), findsOneWidget);
    expect(find.text('重试启动'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(find.text('错误页'), findsNothing);

    await tester.tap(find.text('重试启动'));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
  });

  testWidgets('初始化阶段不显示恢复操作', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: StartupRecoveryScreen()),
    );

    expect(find.text('正在准备应用'), findsOneWidget);
    expect(find.text('重试启动'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
