import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('应用根组件在更新门禁启用时提供方向性上下文', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(tester.takeException(), isNull);
    final repository = Provider.of<AcademicRepository>(
      tester.element(find.byType(AppUpdateGate)),
      listen: false,
    );
    expect(repository.sourceKind, AcademicSourceKind.legacy);
  });

  testWidgets('应用字体档位叠加系统字体缩放并限制组合倍率', (tester) async {
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
    expect(scaler.scale(20), closeTo(30, 0.001));
  });

  testWidgets('真实应用装配中教务补交能读取当前 App 登录会话', (tester) async {
    await tester.pumpWidget(const MyApp());
    final context = tester.element(find.byType(AppUpdateGate));
    final auth = context.read<AuthProvider>();
    final client = context.read<AcademicIdentityClient>();
    expect(client.sessionEpoch, isNotNull);
    expect(client.sessionEpoch!(), auth.accountSessionEpoch);
  });

  testWidgets('真实应用装配中教务核验完成回调能刷新 App 资料', (tester) async {
    await tester.pumpWidget(const MyApp());
    final repository = tester
        .element(find.byType(AppUpdateGate))
        .read<AcademicRepository>() as AcademicProviderRouterRepository;
    expect(repository.onIdentityVerified, isNotNull);
    await repository.onIdentityVerified!();
    expect(tester.takeException(), isNull);
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
    expect(find.byType(AppUpdateGate), findsOneWidget);
  });
}
