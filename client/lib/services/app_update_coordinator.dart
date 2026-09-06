import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update_info.dart';
import '../platform/app_platform.dart';
import '../platform/platform_capabilities.dart';
import '../platform/update_download_bridge.dart';
import 'app_update_api.dart';
import 'app_update_cache.dart';
import 'app_update_preferences.dart';

/// 发布策略与下载进度刻意分离：前者决定是否提示用户，后者只描述包体准备过程。
enum AppUpdateRequirement { none, optional, required }

/// 兼容旧调用点的派生态，新增代码应使用 [requirement] 与 [downloadState]。
@Deprecated('请分别使用 AppUpdateRequirement 和 AppUpdateDownloadState')
enum AppUpdatePhase {
  initializing,
  checking,
  allowed,
  optional,
  required,
  downloading,
  readyToInstall,
  installing,
}

class AppVersionHeaders {
  static Future<AppVersionHeaders>? _loading;
  static const _fallbackVersionName = String.fromEnvironment(
    'APP_VERSION_NAME',
    defaultValue: '1.6.13',
  );
  static const _fallbackVersionCode = int.fromEnvironment(
    'APP_VERSION_CODE',
    defaultValue: 1613,
  );

  final String versionName;
  final int versionCode;
  const AppVersionHeaders._(this.versionName, this.versionCode);

  @visibleForTesting
  static AppVersionHeaders forTesting({
    String versionName = '1.6.1',
    int versionCode = 1601,
  }) =>
      AppVersionHeaders._(versionName, versionCode);

  static Future<AppVersionHeaders> load() => _loading ??= _load();

  static Future<AppVersionHeaders> _load() async {
    if (AppPlatforms.current.isOhos) {
      return const AppVersionHeaders._(
          _fallbackVersionName, _fallbackVersionCode);
    }
    try {
      final info = await PackageInfo.fromPlatform();
      final code = int.tryParse(info.buildNumber.trim());
      if (code == null || code <= 0 || info.version.trim().isEmpty) {
        throw StateError('应用版本信息无效');
      }
      return AppVersionHeaders._(info.version.trim(), code);
    } catch (error) {
      debugPrint('读取应用版本失败，使用构建兜底版本: $error');
      return const AppVersionHeaders._(
          _fallbackVersionName, _fallbackVersionCode);
    }
  }

  Map<String, String> toHeaders() => {
        'X-App-Platform': AppPlatforms.current.wireName,
        'X-App-Channel': 'stable',
        'X-App-Version-Name': versionName,
        'X-App-Version-Code': versionCode.toString(),
      };
}

/// 根级更新提示协调器。它从不绘制全屏门禁；服务端 426 仍负责收紧业务 API。
class AppUpdateCoordinator extends ChangeNotifier {
  AppUpdateCoordinator({
    AppUpdateApi? api,
    AppUpdateCache? cache,
    AppUpdatePreferences? preferences,
    UpdateDownloadBridge? downloadBridge,
    Future<AppVersionHeaders> Function()? versionHeadersLoader,
  })  : _api = api ?? AppUpdateApi(),
        _cache = cache ?? AppUpdateCache(),
        _preferences = preferences ?? AppUpdatePreferences(),
        _downloadBridge = downloadBridge ?? UpdateDownloadBridge(),
        _versionHeadersLoader = versionHeadersLoader ?? AppVersionHeaders.load;

  final AppUpdateApi _api;
  final AppUpdateCache _cache;
  final AppUpdatePreferences _preferences;
  final UpdateDownloadBridge _downloadBridge;
  final Future<AppVersionHeaders> Function() _versionHeadersLoader;

  AppUpdateRequirement _requirement = AppUpdateRequirement.none;
  NativeUpdateDownloadStatus _downloadStatus = NativeUpdateDownloadStatus.idle;
  AppUpdateInfo? _info;
  String? _errorMessage;
  DateTime? _lastSuccessfulCheckAt;
  bool _initialized = false;
  bool _checking = false;
  bool _requiredByApi426 = false;
  bool _requiredByCache = false;
  bool _optionalDeferred = false;
  Future<void>? _deferredInitialCheck;
  Timer? _downloadPollingTimer;

  AppUpdateRequirement get requirement =>
      _requiredByApi426 ? AppUpdateRequirement.required : _requirement;
  AppUpdateInfo? get info => _info;
  NativeUpdateDownloadStatus get downloadStatus => _downloadStatus;
  AppUpdateDownloadState get downloadState => _downloadStatus.state;
  String? get errorMessage => _errorMessage;
  bool get isRequired => requirement == AppUpdateRequirement.required;
  bool get isDownloading => _downloadStatus.isActive;
  bool get hasReadyPackage =>
      _downloadStatus.state == AppUpdateDownloadState.ready;
  bool get isBlocking => false;
  bool get shouldPromptOptional =>
      requirement == AppUpdateRequirement.optional &&
      !_optionalDeferred &&
      _downloadStatus.state == AppUpdateDownloadState.idle;

  /// 旧界面与测试的兼容投影；它不再决定任何全屏渲染。
  AppUpdatePhase get phase {
    if (!_initialized) return AppUpdatePhase.initializing;
    if (_checking) return AppUpdatePhase.checking;
    if (isRequired) return AppUpdatePhase.required;
    return switch (_downloadStatus.state) {
      AppUpdateDownloadState.queued ||
      AppUpdateDownloadState.downloading ||
      AppUpdateDownloadState.verifying =>
        AppUpdatePhase.downloading,
      AppUpdateDownloadState.ready => AppUpdatePhase.readyToInstall,
      _ when requirement == AppUpdateRequirement.optional =>
        AppUpdatePhase.optional,
      _ => AppUpdatePhase.allowed,
    };
  }

  Future<void> startDeferredInitialCheck() =>
      _deferredInitialCheck ??= initialize();

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final headers = await _versionHeadersLoader();
      final cached = await _cache.read();
      if (cached != null) {
        _lastSuccessfulCheckAt = cached.checkedAt;
        if (cached.info.updateType == AppUpdateType.required &&
            headers.versionCode < cached.info.minimumSupportedVersionCode) {
          _info = cached.info;
          _requiredByCache = true;
          _requirement = AppUpdateRequirement.required;
        }
      }
    } catch (error) {
      _errorMessage = '读取本机版本信息失败: $error';
    }
    notifyListeners();
    await check(force: true, initial: true);
  }

  Future<void> check({
    bool force = false,
    bool manual = false,
    bool initial = false,
  }) async {
    if (_checking) return;
    if (!_initialized) {
      await initialize();
      return;
    }
    if (!force && !_shouldCheckNow()) return;

    _checking = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final headers = await _versionHeadersLoader();
      final next = await _api.checkUpdate(
        platform: AppPlatforms.current.wireName,
        channel: 'stable',
        versionName: headers.versionName,
        versionCode: headers.versionCode,
      );
      final previous = _info;
      _info = next;
      _lastSuccessfulCheckAt = DateTime.now().toUtc();
      unawaited(_cache.write(next, _lastSuccessfulCheckAt!).catchError((_) {}));
      _requiredByCache = false;
      _requirement = switch (next.updateType) {
        AppUpdateType.required => AppUpdateRequirement.required,
        AppUpdateType.optional => AppUpdateRequirement.optional,
        AppUpdateType.none => AppUpdateRequirement.none,
      };
      if (previous?.latestVersionCode != next.latestVersionCode) {
        _optionalDeferred = false;
      }
      await _refreshDownloadStatus(next);

      // 静默只对普通更新生效；手动检查必须让用户先确认下载。
      if (!manual &&
          next.updateType == AppUpdateType.optional &&
          next.deliveryMode == AppUpdateDeliveryMode.directPackage &&
          _downloadStatus.state == AppUpdateDownloadState.idle) {
        final preferences = await _preferences.read();
        if (preferences.silentDownload) {
          try {
            await enqueueDownload(wifiOnly: preferences.wifiOnly);
          } catch (error) {
            // 下载排队失败不能把已确认的 optional 发布误判为“没有更新”。
            _errorMessage = _errorText(error);
          }
        }
      }
    } catch (error) {
      _errorMessage = _errorText(error);
      if (!_requiredByApi426 && !_requiredByCache) {
        _requirement = AppUpdateRequirement.none;
      }
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void requireUpdateFromApi() {
    _requiredByApi426 = true;
    _requirement = AppUpdateRequirement.required;
    notifyListeners();
    unawaited(check(force: true));
  }

  Future<void> onAppResumed() async {
    if (!_initialized) return;
    await _refreshCurrentDownloadStatus();
    if (!_requiredByApi426) await check();
  }

  /// 关闭“允许后台继续下载”时，离开前台立即暂停 WorkManager 任务并保留分片。
  Future<void> onAppBackgrounded() async {
    if (!isDownloading) return;
    final preferences = await _preferences.read();
    if (!preferences.backgroundDownload) await cancelDownload();
  }

  Future<void> deferOptionalUpdate() async {
    if (requirement != AppUpdateRequirement.optional) return;
    _optionalDeferred = true;
    notifyListeners();
  }

  /// 保留旧名称，行为由“忽略版本”改为本次不再弹窗，不会阻止静默下载策略。
  Future<void> ignoreOptionalUpdate() => deferOptionalUpdate();

  Future<void> enqueueDownload({bool? wifiOnly}) async {
    final release = _directReleaseOrThrow();
    final preferences = await _preferences.read();
    await _downloadBridge.enqueue(
      release,
      wifiOnly: wifiOnly ?? preferences.wifiOnly,
      allowBackground: preferences.backgroundDownload,
    );
    await _refreshDownloadStatus(release);
    _startDownloadPolling();
    notifyListeners();
  }

  /// 兼容原按钮入口：ready 时仅打开安装器，否则排队后台下载，绝不串行下载后安装。
  Future<void> downloadOrInstall() async {
    if (hasReadyPackage) {
      await installPreparedUpdate();
      return;
    }
    await enqueueDownload(wifiOnly: false);
  }

  Future<void> installReadyPackage() => installPreparedUpdate();

  Future<void> installPreparedUpdate() async {
    final release = _directReleaseOrThrow();
    if (!hasReadyPackage) throw StateError('更新包尚未准备完成');
    try {
      await _downloadBridge.installPrepared(release);
    } catch (error) {
      _errorMessage = _errorText(error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> cancelDownload() async {
    final release = _info;
    if (release == null ||
        release.deliveryMode != AppUpdateDeliveryMode.directPackage) {
      return;
    }
    await _downloadBridge.cancel(release);
    await _refreshDownloadStatus(release);
    _downloadPollingTimer?.cancel();
    _downloadPollingTimer = null;
    notifyListeners();
  }

  Future<void> refreshDownloadStatus() => _refreshCurrentDownloadStatus();

  Future<void> _refreshCurrentDownloadStatus() async {
    final release = _info;
    if (release == null ||
        release.deliveryMode != AppUpdateDeliveryMode.directPackage) {
      return;
    }
    await _refreshDownloadStatus(release);
    notifyListeners();
  }

  Future<void> _refreshDownloadStatus(AppUpdateInfo release) async {
    if (!PlatformCapabilities.current.supportsInAppPackageInstall) {
      _downloadStatus = NativeUpdateDownloadStatus.idle;
      return;
    }
    try {
      _downloadStatus = await _downloadBridge.query(release);
      if (_downloadStatus.isActive) _startDownloadPolling();
    } catch (_) {
      // 原生桥接不可用不能阻断版本检查；下次进入 Android 前台会重新读取。
      _downloadStatus = NativeUpdateDownloadStatus.idle;
    }
  }

  void _startDownloadPolling() {
    _downloadPollingTimer ??=
        Timer.periodic(const Duration(milliseconds: 750), (_) async {
      await _refreshCurrentDownloadStatus();
      if (!_downloadStatus.isActive) {
        _downloadPollingTimer?.cancel();
        _downloadPollingTimer = null;
      }
    });
  }

  AppUpdateInfo _directReleaseOrThrow() {
    final release = _info;
    if (release == null ||
        !release.updateAvailable ||
        release.deliveryMode != AppUpdateDeliveryMode.directPackage ||
        release.downloadUrl.isEmpty) {
      throw StateError('更新包信息不完整，请重新检查');
    }
    return release;
  }

  bool _shouldCheckNow() {
    final checkedAt = _lastSuccessfulCheckAt;
    if (checkedAt == null) return true;
    final seconds = _info?.checkAfterSeconds ?? 300;
    return DateTime.now().toUtc().difference(checkedAt) >=
        Duration(seconds: seconds.clamp(60, 86400));
  }

  String _errorText(Object error) {
    if (error is AppUpdateApiException) {
      return error.toString().replaceFirst(RegExp(r'^.*?\): '), '');
    }
    return '更新操作失败: $error';
  }

  @override
  void dispose() {
    _downloadPollingTimer?.cancel();
    super.dispose();
  }
}

final AppUpdateCoordinator appUpdateCoordinator = AppUpdateCoordinator();
