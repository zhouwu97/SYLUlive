import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

class _NoopAppUpdateCoordinator extends AppUpdateCoordinator {
  int initializeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<void> onAppResumed() async {}
}

class _RequiredAppUpdateCoordinator extends _NoopAppUpdateCoordinator {
  int downloadCalls = 0;

  @override
  bool get isRequired => true;

  @override
  Future<void> enqueueDownload(
      {bool? wifiOnly, bool userInitiated = false}) async {
    downloadCalls++;
  }

  @override
  AppUpdateInfo get info => AppUpdateInfo(
        updateAvailable: true,
        updateType: AppUpdateType.required,
        currentVersionName: '1.6.1',
        currentVersionCode: 1601,
        latestVersionName: '1.6.4',
        latestVersionCode: 1604,
        minimumSupportedVersionCode: 1602,
        title: '发现必须安装的新版本',
        changelog: '修复已知问题',
        fileSize: 1024,
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        downloadUrl: 'https://example.com/app.apk',
        deliveryMode: AppUpdateDeliveryMode.directPackage,
        actionUrl: '',
        publishedAt: null,
        checkAfterSeconds: 21600,
      );
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
    expect(find.text('正在检查更新'), findsNothing);
    expect(coordinator.initializeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  test('初始化阶段不覆盖应用页面', () {
    final coordinator = AppUpdateCoordinator();
    addTearDown(coordinator.dispose);

    expect(coordinator.phase, AppUpdatePhase.initializing);
    expect(coordinator.isBlocking, isFalse);
  });

  testWidgets('低于最低支持版本时显示紧凑更新下载对话框', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final coordinator = _RequiredAppUpdateCoordinator();
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
          home: const Scaffold(body: Text('首页')),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('需要更新沈理校园'), findsOneWidget);
    expect(find.text('后台下载'), findsOneWidget);

    await tester.tap(find.text('后台下载'));
    await tester.pump();
    expect(coordinator.downloadCalls, 1);
  });
}
