import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/update_download_bridge.dart';
import 'package:shenliyuan/services/app_update_preferences.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/app_update_api.dart';
import 'package:shenliyuan/services/app_update_cache.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';

class _MemoryUpdateCache extends AppUpdateCache {
  AppUpdateCacheEntry? entry;

  @override
  Future<AppUpdateCacheEntry?> read() async => entry;

  @override
  Future<void> write(AppUpdateInfo info, DateTime checkedAt) async {}
}

class _FakeUpdateApi extends AppUpdateApi {
  AppUpdateInfo? response;
  Future<AppUpdateInfo>? pendingResponse;
  Object? failure;

  @override
  Future<AppUpdateInfo> checkUpdate({
    required String platform,
    required String channel,
    required String versionName,
    required int versionCode,
  }) async {
    final error = failure;
    if (error != null) throw error;
    final pending = pendingResponse;
    if (pending != null) return pending;
    return response!;
  }
}

AppUpdateInfo _noneInfo() => AppUpdateInfo(
      updateAvailable: false,
      updateType: AppUpdateType.none,
      currentVersionName: '1.6.1',
      currentVersionCode: 1601,
      latestVersionName: '1.6.4',
      latestVersionCode: 1604,
      minimumSupportedVersionCode: 1602,
      title: '',
      changelog: '',
      fileSize: 0,
      sha256: '',
      downloadUrl: '',
      deliveryMode: AppUpdateDeliveryMode.directPackage,
      actionUrl: '',
      publishedAt: null,
      checkAfterSeconds: 21600,
    );

AppUpdateInfo _requiredInfo() => AppUpdateInfo(
      updateAvailable: true,
      updateType: AppUpdateType.required,
      currentVersionName: '1.6.1',
      currentVersionCode: 1601,
      latestVersionName: '1.6.4',
      latestVersionCode: 1604,
      minimumSupportedVersionCode: 1602,
      title: '需要更新',
      changelog: '',
      fileSize: 1024,
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      downloadUrl: 'https://example.com/app.apk',
      deliveryMode: AppUpdateDeliveryMode.directPackage,
      actionUrl: '',
      publishedAt: null,
      checkAfterSeconds: 21600,
    );

Future<void> _settleAsyncWork() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

AppUpdateCoordinator _buildCoordinator(
  _FakeUpdateApi api, {
  AppUpdateCache? cache,
}) {
  return AppUpdateCoordinator(
    api: api,
    cache: cache ?? _MemoryUpdateCache(),
    versionHeadersLoader: () async => AppVersionHeaders.forTesting(),
  );
}

AppUpdateInfo _betaRelease(String channel, int version,
        {String type = 'optional'}) =>
    AppUpdateInfo.fromJson({
      'channel': channel,
      'update_available': type != 'none',
      'update_type': type,
      'current_version_name': '2.0.0',
      'current_version_code': 2000,
      'latest_version_name': '$version',
      'latest_version_code': version,
      'minimum_supported_version_code': 1,
      'title': channel,
      'changelog': 'synthetic audit',
      'file_size': 100,
      'sha256': 'a' * 64,
      'download_url': 'https://example.invalid/$channel.apk',
      'delivery_mode': 'direct_package',
      'check_after_seconds': 60,
    });

class _BetaMemoryPreferences extends AppUpdatePreferences {
  bool beta = false;
  @override
  Future<AppUpdatePreferencesSnapshot> read() async =>
      AppUpdatePreferencesSnapshot(
          silentDownload: false,
          wifiOnly: true,
          backgroundDownload: true,
          betaUpdates: beta);
  @override
  Future<void> setBetaUpdates(bool value) async {
    beta = value;
  }
}

class _BetaMemoryCache extends AppUpdateCache {
  final written = <AppUpdateInfo>[];
  @override
  Future<AppUpdateCacheEntry?> read() async => null;
  @override
  Future<void> write(AppUpdateInfo info, DateTime at) async {
    written.add(info);
  }
}

class _BetaFakeBridge extends UpdateDownloadBridge {
  final queued = <String>[];
  @override
  Future<NativeUpdateDownloadStatus> query(AppUpdateInfo info) async =>
      NativeUpdateDownloadStatus.idle;
  @override
  Future<void> enqueue(AppUpdateInfo info,
      {required bool wifiOnly,
      required bool allowBackground,
      required bool userInitiated}) async {
    queued.add(info.channel);
  }
}

class _BetaChannelApi extends AppUpdateApi {
  AppUpdateInfo stable = _betaRelease('stable', 2000, type: 'none');
  AppUpdateInfo beta = _betaRelease('beta', 1000);
  bool failStable = false, failBeta = false;
  Future<AppUpdateInfo>? pendingBeta;
  final calls = <String>[];
  @override
  Future<AppUpdateInfo> checkUpdate(
      {required String platform,
      required String channel,
      required String versionName,
      required int versionCode}) async {
    calls.add(channel);
    if (channel == 'stable') {
      if (failStable) throw const AppUpdateApiException('stable offline');
      return stable;
    }
    if (failBeta) throw const AppUpdateApiException('beta offline');
    return pendingBeta == null ? beta : await pendingBeta!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  test('手动检查等待正在进行的自动检查结果', () async {
    final api = _FakeUpdateApi()..response = _noneInfo();
    final coordinator = _buildCoordinator(api);
    addTearDown(coordinator.dispose);
    await coordinator.initialize();

    final response = Completer<AppUpdateInfo>();
    api.pendingResponse = response.future;
    final automatic = coordinator.check(force: true);
    var manualFinished = false;
    final manual = coordinator.check(force: true, manual: true).then((_) {
      manualFinished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(manualFinished, isFalse);

    response.complete(_requiredInfo());
    await manual;
    expect(coordinator.info?.latestVersionCode, 1604);
    expect(coordinator.isRequired, isTrue);
    await automatic;
  });

  test('426 在初始化前发生且更新接口失败时仍保持强制门禁', () async {
    final api = _FakeUpdateApi()
      ..failure = const AppUpdateApiException('offline');
    final coordinator = _buildCoordinator(api);
    addTearDown(coordinator.dispose);

    coordinator.requireUpdateFromApi();
    await _settleAsyncWork();

    expect(coordinator.phase, AppUpdatePhase.required);
    expect(coordinator.isRequired, isTrue);
  });

  test('426 后服务器返回无更新也不能解除强制门禁', () async {
    final api = _FakeUpdateApi()..response = _noneInfo();
    final coordinator = _buildCoordinator(api);
    addTearDown(coordinator.dispose);

    coordinator.requireUpdateFromApi();
    await _settleAsyncWork();

    expect(coordinator.phase, AppUpdatePhase.required);
    expect(coordinator.isRequired, isTrue);
  });

  test('强制门禁回到前台时不触发降级检查', () async {
    final api = _FakeUpdateApi()..response = _noneInfo();
    final coordinator = _buildCoordinator(api);
    addTearDown(coordinator.dispose);

    coordinator.requireUpdateFromApi();
    await _settleAsyncWork();
    await coordinator.onAppResumed();

    expect(coordinator.phase, AppUpdatePhase.required);
  });

  test('缓存 required 在服务器成功返回 none 后可以解除门禁', () async {
    final api = _FakeUpdateApi()..response = _noneInfo();
    final cache = _MemoryUpdateCache()
      ..entry = AppUpdateCacheEntry(
        info: _requiredInfo(),
        checkedAt: DateTime.now().toUtc(),
      );
    final coordinator = _buildCoordinator(api, cache: cache);
    addTearDown(coordinator.dispose);

    await coordinator.initialize();

    expect(coordinator.phase, AppUpdatePhase.allowed);
    expect(coordinator.isRequired, isFalse);
  });

  test('服务器 required 后下一次成功返回 none 可以解除服务器门禁', () async {
    final api = _FakeUpdateApi()..response = _requiredInfo();
    final coordinator = _buildCoordinator(api);
    addTearDown(coordinator.dispose);

    await coordinator.initialize();
    expect(coordinator.phase, AppUpdatePhase.required);

    api.response = _noneInfo();
    await coordinator.check(force: true);

    expect(coordinator.phase, AppUpdatePhase.allowed);
    expect(coordinator.isRequired, isFalse);
  });

  group('Beta 通道隔离', () {
    late _BetaChannelApi api;
    late _BetaMemoryPreferences preferences;
    late _BetaMemoryCache cache;
    late _BetaFakeBridge bridge;
    late AppUpdateCoordinator coordinator;
    setUp(() {
      AppPlatforms.currentOverrides = AppPlatform.android;
      api = _BetaChannelApi();
      preferences = _BetaMemoryPreferences();
      cache = _BetaMemoryCache();
      bridge = _BetaFakeBridge();
      coordinator = AppUpdateCoordinator(
          api: api,
          preferences: preferences,
          cache: cache,
          downloadBridge: bridge,
          versionHeadersLoader: () async => AppVersionHeaders.forTesting(
              versionName: '2.0.0', versionCode: 2000));
    });
    tearDown(() {
      coordinator.dispose();
      AppPlatforms.currentOverrides = null;
    });
    test('unsubscribed users only check stable', () async {
      await coordinator.initialize();
      expect(api.calls, ['stable']);
      expect(coordinator.betaInfo, isNull);
    });
    test('beta below installed build is separate and never cached or enqueued',
        () async {
      preferences.beta = true;
      await coordinator.initialize();
      expect(coordinator.info?.channel, 'stable');
      expect(coordinator.requirement, AppUpdateRequirement.none);
      expect(coordinator.betaInfo?.channel, 'beta');
      expect(coordinator.betaInfo?.latestVersionCode, 1000);
      expect(coordinator.shouldPromptBeta, isTrue);
      expect(bridge.queued, isEmpty);
      expect(cache.written.map((entry) => entry.channel), ['stable']);
    });
    test('stable check failure retains independent beta success', () async {
      preferences.beta = true;
      api.failStable = true;
      await coordinator.initialize();
      expect(coordinator.errorMessage, contains('stable offline'));
      expect(coordinator.betaErrorMessage, isNull);
      expect(coordinator.betaInfo, isNotNull);
    });
    test('beta check failure cannot erase successful stable policy', () async {
      preferences.beta = true;
      api.stable = _betaRelease('stable', 2100);
      api.failBeta = true;
      await coordinator.initialize();
      expect(coordinator.info?.latestVersionCode, 2100);
      expect(coordinator.requirement, AppUpdateRequirement.optional);
      expect(coordinator.errorMessage, isNull);
      expect(coordinator.betaErrorMessage, contains('beta offline'));
    });
    test('unsubscribe rejects late beta response and rechecks only stable',
        () async {
      preferences.beta = true;
      final gate = Completer<AppUpdateInfo>();
      api.pendingBeta = gate.future;
      final initial = coordinator.initialize();
      while (!api.calls.contains('beta')) {
        await Future<void>.delayed(Duration.zero);
      }
      final disabled = coordinator.setBetaUpdates(false);
      await Future<void>.delayed(Duration.zero);
      gate.complete(_betaRelease('beta', 1000));
      await initial;
      await disabled;
      expect(coordinator.betaInfo, isNull);
      expect(coordinator.shouldPromptBeta, isFalse);
      expect(api.calls, ['stable', 'beta', 'stable']);
    });
    test('same beta is deferred and new beta release prompts again', () async {
      preferences.beta = true;
      await coordinator.initialize();
      coordinator.deferBetaDownload();
      await coordinator.check(force: true);
      expect(coordinator.shouldPromptBeta, isFalse);
      api.beta = _betaRelease('beta', 1001);
      await coordinator.check(force: true);
      expect(coordinator.shouldPromptBeta, isTrue);
    });
    test('stable required policy takes precedence over beta prompt', () async {
      preferences.beta = true;
      api.stable = _betaRelease('stable', 2100, type: 'required');
      await coordinator.initialize();
      expect(coordinator.isRequired, isTrue);
      expect(coordinator.betaInfo, isNotNull);
      expect(coordinator.shouldPromptBeta, isFalse);
      expect(bridge.queued, isEmpty);
    });
  });
}
