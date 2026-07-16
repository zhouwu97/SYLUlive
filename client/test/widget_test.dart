import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/main.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

void main() {
  testWidgets('应用根组件在更新门禁启用时提供方向性上下文', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(tester.takeException(), isNull);
  });

  testWidgets('冷启动检查更新时不覆盖原有开屏内容', (tester) async {
    final coordinator = AppUpdateCoordinator();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: coordinator,
        child: const MaterialApp(
          home: AppUpdateGate(
            child: Scaffold(body: Center(child: Text('原有开屏内容'))),
          ),
        ),
      ),
    );

    expect(find.text('原有开屏内容'), findsOneWidget);
    expect(find.byType(AppUpdateScreen), findsNothing);
  });
}
