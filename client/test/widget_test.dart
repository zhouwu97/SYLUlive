import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('应用根组件在更新门禁启用时提供方向性上下文', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(tester.takeException(), isNull);
  });

  testWidgets('应用字体档位叠加系统字体缩放并保留更新门禁', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'font_size_preset': 'extra_large',
    });
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    final gateFinder = find.byType(AppUpdateGate);
    expect(gateFinder, findsOneWidget);
    final scaler = MediaQuery.textScalerOf(tester.element(gateFinder));
    expect(scaler.scale(20), closeTo(33.8, 0.001));
  });

  testWidgets('冷启动检查更新时不覆盖原有开屏内容', (tester) async {
    final coordinator = AppUpdateCoordinator();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: coordinator,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: AppUpdateGate(
            navigatorKey: navigatorKey,
            child: const Scaffold(body: Center(child: Text('原有开屏内容'))),
          ),
        ),
      ),
    );

    expect(find.text('原有开屏内容'), findsOneWidget);
    expect(find.byType(AppUpdateScreen), findsNothing);
  });
}
