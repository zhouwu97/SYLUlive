import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';
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
      downloadUrl: 'https://example.com/update.apk',
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

void main() {
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
}
