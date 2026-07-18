import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/services/app_update_api.dart';
import 'package:shenliyuan/services/app_update_cache.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';

class _MemoryUpdateCache extends AppUpdateCache {
  @override
  Future<AppUpdateCacheEntry?> read() async => null;

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

Future<void> _settleAsyncWork() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

AppUpdateCoordinator _buildCoordinator(_FakeUpdateApi api) {
  return AppUpdateCoordinator(
    api: api,
    cache: _MemoryUpdateCache(),
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
}
