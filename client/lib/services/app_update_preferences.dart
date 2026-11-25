import '../platform/contracts/preferences_store.dart';

/// 更新策略只保存用户偏好；下载任务的真实状态由 Android 原生 manifest 持久化。
class AppUpdatePreferences {
  static const _silentDownloadKey = 'app_update_silent_download_v1';
  static const _wifiOnlyKey = 'app_update_wifi_only_v1';
  static const _backgroundDownloadKey = 'app_update_background_download_v1';
  static const _betaUpdatesKey = 'app_update_beta_updates_v1';

  Future<AppUpdatePreferencesSnapshot> read() async {
    final store = await AppPreferencesStore.getInstance();
    return AppUpdatePreferencesSnapshot(
      silentDownload: store.getBool(_silentDownloadKey) ?? true,
      wifiOnly: store.getBool(_wifiOnlyKey) ?? true,
      backgroundDownload: store.getBool(_backgroundDownloadKey) ?? true,
      betaUpdates: store.getBool(_betaUpdatesKey) ?? false,
    );
  }

  Future<void> setSilentDownload(bool value) async {
    final store = await AppPreferencesStore.getInstance();
    await store.setBool(_silentDownloadKey, value);
  }

  Future<void> setBetaUpdates(bool value) async {
    final store = await AppPreferencesStore.getInstance();
    if (!await store.setBool(_betaUpdatesKey, value)) {
      throw StateError('无法保存 Beta 测试版通知设置');
    }
  }

  Future<void> setWifiOnly(bool value) async {
    final store = await AppPreferencesStore.getInstance();
    await store.setBool(_wifiOnlyKey, value);
  }

  Future<void> setBackgroundDownload(bool value) async {
    final store = await AppPreferencesStore.getInstance();
    await store.setBool(_backgroundDownloadKey, value);
  }
}

class AppUpdatePreferencesSnapshot {
  const AppUpdatePreferencesSnapshot({
    required this.silentDownload,
    required this.wifiOnly,
    required this.backgroundDownload,
    this.betaUpdates = false,
  });

  final bool silentDownload;
  final bool wifiOnly;
  final bool backgroundDownload;
  final bool betaUpdates;
}
