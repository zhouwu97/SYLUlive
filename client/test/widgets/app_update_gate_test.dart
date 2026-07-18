import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

class _NoopAppUpdateCoordinator extends AppUpdateCoordinator {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> onAppResumed() async {}
}

void main() {
  testWidgets('更新门禁位于 MaterialApp 内时启动不触发 Directionality 错误', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final coordinator = _NoopAppUpdateCoordinator();
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppUpdateCoordinator>.value(
        value: coordinator,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => AppUpdateGate(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('ready')),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
