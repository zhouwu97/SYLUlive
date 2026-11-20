import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/platform/update_download_bridge.dart';
import 'package:shenliyuan/services/app_update_api.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

class _PublishedUpdateApi extends AppUpdateApi {
  int? latestVersionCode;
  int requests = 0;
  bool offline = false;

  @override
  Future<AppUpdateInfo> checkUpdate({
    required String platform,
    required String channel,
    required String versionName,
    required int versionCode,
  }) async {
    requests++;
    if (offline) throw const AppUpdateApiException('offline');
    final latest = latestVersionCode;
    return AppUpdateInfo.fromJson({
      'update_available': latest != null,
      'update_type': latest == null ? 'none' : 'optional',
      'current_version_name': versionName,
      'current_version_code': versionCode,
      'latest_version_name':
          latest == null ? versionName : '1.7.${latest - 1702}',
      'latest_version_code': latest ?? versionCode,
      'minimum_supported_version_code': versionCode,
      'changelog': '修复课表',
      'file_size': 1024,
      'sha256': 'a' * 64,
      'download_url': 'https://example.com/app.apk',
      'check_after_seconds': 21600,
    });
  }
}

class _QueuedUpdateBridge extends UpdateDownloadBridge {
  var state = AppUpdateDownloadState.idle;
  int? installedVersion;

  @override
  Future<void> enqueue(
    AppUpdateInfo info, {
    required bool wifiOnly,
    required bool allowBackground,
    required bool userInitiated,
  }) async {
    state = AppUpdateDownloadState.queued;
  }

  @override
  Future<NativeUpdateDownloadStatus> query(AppUpdateInfo info) async =>
      NativeUpdateDownloadStatus(
        state: state,
        receivedBytes: 0,
        totalBytes: info.fileSize,
        bytesPerSecond: 0,
      );

  @override
  Future<void> installPrepared(AppUpdateInfo info) async {
    installedVersion = info.latestVersionCode;
  }
}

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
  _RequiredAppUpdateCoordinator({this.store = false});

  final bool store;
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
        deliveryMode: store
            ? AppUpdateDeliveryMode.externalMarket
            : AppUpdateDeliveryMode.directPackage,
        actionUrl: store ? 'https://apps.apple.com/cn/app/id123456789' : '',
        publishedAt: null,
        checkAfterSeconds: 21600,
      );
}

class _StoreNavigator implements ExternalNavigator {
  bool opened = false;
  final requests = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    requests.add(uri);
    return opened;
  }
}

class _FailedAppUpdateCoordinator extends _NoopAppUpdateCoordinator {
  _FailedAppUpdateCoordinator({required this.userInitiated});

  final bool userInitiated;
  int retryCalls = 0;

  @override
  AppUpdateDownloadState get downloadState => AppUpdateDownloadState.failed;

  @override
  NativeUpdateDownloadStatus get downloadStatus => NativeUpdateDownloadStatus(
        state: AppUpdateDownloadState.failed,
        receivedBytes: 10,
        totalBytes: 100,
        bytesPerSecond: 0,
        userInitiated: userInitiated,
      );

  @override
  Future<void> enqueueDownload(
      {bool? wifiOnly, bool userInitiated = false}) async {
    retryCalls++;
  }

  @override
  AppUpdateInfo get info => AppUpdateInfo(
        updateAvailable: true,
        updateType: AppUpdateType.optional,
        currentVersionName: '1.7.1',
        currentVersionCode: 1701,
        latestVersionName: '1.7.2',
        latestVersionCode: 1703,
        minimumSupportedVersionCode: 1701,
        title: '发现新版本',
        changelog: '',
        fileSize: 100,
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        downloadUrl: 'https://example.com/app.apk',
        deliveryMode: AppUpdateDeliveryMode.directPackage,
        actionUrl: '',
        publishedAt: null,
        checkAfterSeconds: 21600,
      );
}

Future<void> _pumpGate(
  WidgetTester tester,
  AppUpdateCoordinator coordinator,
) async {
  final navigatorKey = GlobalKey<NavigatorState>();
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
}

void main() {
  AppUpdateCoordinator androidCoordinator(
    _PublishedUpdateApi api,
    _QueuedUpdateBridge bridge,
  ) {
    AppPlatforms.currentOverrides = AppPlatform.android;
    addTearDown(() => AppPlatforms.currentOverrides = null);
    AppPreferencesStore.setMockInitialValues({});
    final coordinator = AppUpdateCoordinator(
      api: api,
      downloadBridge: bridge,
      versionHeadersLoader: () async => AppVersionHeaders.forTesting(
        versionName: '1.7.6',
        versionCode: 1711,
      ),
    );
    addTearDown(coordinator.dispose);
    return coordinator;
  }

  testWidgets('iOS 更新打开 App Store，跳转失败时可重试', (tester) async {
    AppPlatforms.currentOverrides = AppPlatform.ios;
    addTearDown(() => AppPlatforms.currentOverrides = null);
    final previous = ExternalNavigator.current();
    final store = _StoreNavigator();
    ExternalNavigator.register(store);
    addTearDown(() => ExternalNavigator.register(previous));
    final coordinator = _RequiredAppUpdateCoordinator(store: true);
    addTearDown(coordinator.dispose);
    await _pumpGate(tester, coordinator);

    final button =
        find.widgetWithText(FilledButton, '打开 App Store / TestFlight');
    expect(button, findsOneWidget);
    expect(find.text('后台下载'), findsNothing);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(button, findsOneWidget);
    expect(find.text('无法打开应用市场，请重试'), findsOneWidget);
    store.opened = true;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(
        store.requests, List.filled(2, Uri.parse(coordinator.info.actionUrl)));
    expect(coordinator.downloadCalls, 0);
  });

  testWidgets('默认静默下载排队时仍显示新版，并可在下载完成后安装', (tester) async {
    final api = _PublishedUpdateApi()..latestVersionCode = 1712;
    final bridge = _QueuedUpdateBridge();
    final coordinator = androidCoordinator(api, bridge);
    await _pumpGate(tester, coordinator);

    await coordinator.startDeferredInitialCheck();
    await tester.pumpAndSettle();

    expect(coordinator.downloadState, AppUpdateDownloadState.queued);
    expect(find.text('发现新版本 1.7.10'), findsOneWidget);
    expect(find.text('使用当前网络下载'), findsOneWidget);

    bridge.state = AppUpdateDownloadState.ready;
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即安装'));
    await tester.pumpAndSettle();
    expect(bridge.installedVersion, 1712);
  });

  testWidgets('前台自动检查失败后恢复，新版弹出且稍后处理不重复提醒', (tester) async {
    final api = _PublishedUpdateApi()..offline = true;
    final bridge = _QueuedUpdateBridge();
    final coordinator = androidCoordinator(api, bridge);
    await _pumpGate(tester, coordinator);
    await coordinator.startDeferredInitialCheck();
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(coordinator.errorMessage, isNotNull);
    expect(api.requests, 1);

    api.offline = false;
    api.latestVersionCode = 1712;
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.7.10'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.7.10'), findsNothing);

    api.latestVersionCode = 1713;
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.7.11'), findsOneWidget);

    api.latestVersionCode = 1714;
    await coordinator.check(force: true);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.7.11'), findsOneWidget);
    expect(find.text('发现新版本 1.7.12'), findsNothing);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.7.12'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final requests = api.requests;
    bridge.state = AppUpdateDownloadState.ready;
    await tester.pump(const Duration(minutes: 10));
    expect(api.requests, requests);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  testWidgets('静默后台下载失败不弹窗打断当前操作', (tester) async {
    final coordinator = _FailedAppUpdateCoordinator(userInitiated: false);
    addTearDown(coordinator.dispose);

    await _pumpGate(tester, coordinator);

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('更新包下载失败'), findsNothing);
  });

  testWidgets('主动下载失败时区分稍后与立即重试', (tester) async {
    final coordinator = _FailedAppUpdateCoordinator(userInitiated: true);
    addTearDown(coordinator.dispose);

    await _pumpGate(tester, coordinator);

    expect(find.text('更新包下载失败'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('立即重试'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(coordinator.retryCalls, 0);
  });
}
