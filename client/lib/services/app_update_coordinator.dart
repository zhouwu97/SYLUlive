import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update_info.dart';
import '../platform/app_installer.dart';
import '../platform/app_platform.dart';
import 'app_update_api.dart';
import 'app_update_cache.dart';
import 'app_update_download_service.dart';

/// 更新门禁与下载流程的可视状态。
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

/// 所有业务请求共用的 App 版本头。服务端根据 versionCode 做最低版本限制，
/// 因而不能只在版本检查接口上传一次版本信息。
class AppVersionHeaders {
  static Future<AppVersionHeaders>? _loading;

  // 鸿蒙插件未接入 package_info_plus 时，仍须放行业务网络请求。
  // 正式接入后构建脚本可用 dart-define 覆盖这两个兜底值。
  static const _fallbackVersionName = String.fromEnvironment(
    'APP_VERSION_NAME',
    defaultValue: '1.6.2',
  );
  static const _fallbackVersionCode = int.fromEnvironment(
    'APP_VERSION_CODE',
    defaultValue: 1602,
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

  static Future<AppVersionHeaders> load() {
    return _loading ??= _load();
  }

  static Future<AppVersionHeaders> _load() async {
    // package_info_plus 尚无 OHOS 注册器时，MethodChannel 的空回复不会完成。
    // 鸿蒙构建版本由 dart-define 注入，因此无需等待该插件即可安全放行业务请求。
    if (AppPlatforms.current.isOhos) {
      return const AppVersionHeaders._(
        _fallbackVersionName,
        _fallbackVersionCode,
      );
    }
    try {
      final info = await PackageInfo.fromPlatform();
      final versionCode = int.tryParse(info.buildNumber.trim());
      if (versionCode == null ||
          versionCode <= 0 ||
          info.version.trim().isEmpty) {
        throw StateError('应用版本信息无效: ${info.version}+${info.buildNumber}');
      }
      return AppVersionHeaders._(info.version.trim(), versionCode);
    } catch (error) {
      // 非鸿蒙平台读取异常时使用构建兜底版本，避免版本检查阻断业务请求。
      debugPrint('读取应用版本失败，使用构建兜底版本: $error');
      return const AppVersionHeaders._(
        _fallbackVersionName,
        _fallbackVersionCode,
      );
    }
  }

  Map<String, String> toHeaders() => {
        'X-App-Platform': AppPlatforms.current.wireName,
        'X-App-Channel': 'stable',
        'X-App-Version-Name': versionName,
        'X-App-Version-Code': versionCode.toString(),
      };
}

/// 根级更新状态机。所有入口（冷启动、回前台、手动检查、业务接口 426）都调用
/// 这里，避免多个页面自行弹窗后产生相互覆盖或错误放行。
class AppUpdateCoordinator extends ChangeNotifier {
  AppUpdateCoordinator({
    AppUpdateApi? api,
    AppUpdateCache? cache,
    AppUpdateDownloadService? downloadService,
    AppInstaller? installer,
    Future<AppVersionHeaders> Function()? versionHeadersLoader,
  })  : _api = api ?? AppUpdateApi(),
        _cache = cache ?? AppUpdateCache(),
        _downloadService = downloadService ?? AppUpdateDownloadService(),
        _installer = installer ?? AppInstaller(),
        _versionHeadersLoader = versionHeadersLoader ?? AppVersionHeaders.load;

  final AppUpdateApi _api;
  final AppUpdateCache _cache;
  final AppUpdateDownloadService _downloadService;
  final AppInstaller _installer;
  final Future<AppVersionHeaders> Function() _versionHeadersLoader;

  AppUpdatePhase _phase = AppUpdatePhase.initializing;
  AppUpdateInfo? _info;
  AppDownloadProgress? _downloadProgress;
  File? _downloadedApk;
  int? _downloadedVersionCode;
  String? _downloadedSha256;
  String? _errorMessage;
  DateTime? _lastSuccessfulCheckAt;
  bool _initialized = false;
  bool _checking = false;
  bool _requiredByApi426 = false;
  bool _requiredByServer = false;
  bool _requiredByCache = false;
  Future<void>? _deferredInitialCheck;
  CancelToken? _downloadCancelToken;

  bool get _requiredLatched =>
      _requiredByApi426 || _requiredByServer || _requiredByCache;

  AppUpdatePhase get phase => _phase;
  AppUpdateInfo? get info => _info;
  AppDownloadProgress? get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;

  /// 冷启动和回前台检查均在后台完成，不能遮挡原有开屏或当前页面。
  /// 仅在已确认强制更新，或用户已进入安装流程后启用全屏门禁。
  bool get isBlocking => switch (_phase) {
        AppUpdatePhase.required ||
        AppUpdatePhase.downloading ||
        AppUpdatePhase.readyToInstall ||
        AppUpdatePhase.installing =>
          true,
        AppUpdatePhase.initializing ||
        AppUpdatePhase.checking ||
        AppUpdatePhase.allowed ||
        AppUpdatePhase.optional =>
          false,
      };
  bool get isRequired =>
      _requiredLatched ||
      _info?.updateType == AppUpdateType.required ||
      _phase == AppUpdatePhase.required;
  bool get isDownloading => _phase == AppUpdatePhase.downloading;
  bool get hasReadyPackage => _phase == AppUpdatePhase.readyToInstall;

  /// 延迟的首次检查入口。首页首屏结束或兜底计时器都可以调用，实际请求只会启动一次。
  Future<void> startDeferredInitialCheck() {
    return _deferredInitialCheck ??= initialize();
  }

  /// 启动时先读取缓存的 required 策略，再联网重验。旧缓存只能收紧门禁，不能
  /// 把新的强制策略降级为可用状态。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_requiredLatched && _phase != AppUpdatePhase.required) {
      _phase = AppUpdatePhase.checking;
      notifyListeners();
    }

    try {
      final headers = await _versionHeadersLoader();
      final cached = await _cache.read();
      if (cached != null) {
        _lastSuccessfulCheckAt = cached.checkedAt;
        if (cached.info.updateType == AppUpdateType.required &&
            headers.versionCode < cached.info.minimumSupportedVersionCode) {
          _info = cached.info;
          _requiredByCache = true;
          _phase = AppUpdatePhase.required;
          notifyListeners();
        }
      }
    } catch (error) {
      _errorMessage = '读取本机版本信息失败: $error';
    }

    await check(force: true, initial: true);
  }

  /// 检查服务器策略。前后台恢复时按服务端 check_after_seconds 限流；手动检查
  /// 与 426 强制刷新可传 force=true 绕过间隔。
  Future<void> check(
      {bool force = false, bool manual = false, bool initial = false}) async {
    if (_checking) return;
    if (!_initialized) {
      await initialize();
      return;
    }
    if (!force && !_shouldCheckNow()) return;

    _checking = true;
    _errorMessage = null;
    if (initial && !_requiredLatched && _phase != AppUpdatePhase.required) {
      _phase = AppUpdatePhase.checking;
      notifyListeners();
    }
    try {
      final headers = await _versionHeadersLoader();
      final info = await _api.checkUpdate(
        platform: AppPlatforms.current.wireName,
        channel: 'stable',
        versionName: headers.versionName,
        versionCode: headers.versionCode,
      );
      _info = info;
      _lastSuccessfulCheckAt = DateTime.now().toUtc();
      // 缓存故障不能影响已经从服务端获得的有效策略；下一次成功检查会覆盖它。
      unawaited(_cache.write(info, _lastSuccessfulCheckAt!).catchError((_) {}));

      // 成功的服务端响应会覆盖旧缓存策略；只有 426 需要在当前进程中永久锁存。
      _requiredByCache = false;
      _requiredByServer = info.updateType == AppUpdateType.required;
      if (_requiredByApi426) {
        // 426 已由业务接口确认当前版本不可用，任何后续响应都不能解除门禁。
        _phase = AppUpdatePhase.required;
      } else if (_requiredByServer) {
        _phase = AppUpdatePhase.required;
      } else {
        switch (info.updateType) {
          case AppUpdateType.required:
            _phase = AppUpdatePhase.required;
          case AppUpdateType.optional:
            await _cache.clearIgnoredVersionWhenChanged(info.latestVersionCode);
            final ignored = !manual &&
                await _cache.isOptionalVersionIgnored(info.latestVersionCode);
            _phase = ignored ? AppUpdatePhase.allowed : AppUpdatePhase.optional;
          case AppUpdateType.none:
            _phase = AppUpdatePhase.allowed;
        }
      }
    } catch (error) {
      _errorMessage = _errorText(error);
      // 已锁存的 required 策略（缓存、服务端响应或 426）不能因临时网络错误放行；
      // 其余首次检查失败默认进入应用，避免普通网络故障阻断本地可用功能。
      if (!_requiredByApi426 &&
          !_requiredByServer &&
          !_requiredByCache &&
          _phase != AppUpdatePhase.required) {
        _phase = AppUpdatePhase.allowed;
      }
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 业务接口返回 426 时立即进入强制门禁，并后台重拉完整发布信息。
  void requireUpdateFromApi() {
    _requiredByApi426 = true;
    _phase = AppUpdatePhase.required;
    notifyListeners();
    unawaited(check(force: true));
  }

  /// App 回到前台时调用。若用户从未知来源安装权限页返回，恢复为可点击的
  /// “继续安装”状态；同时按缓存间隔检查是否有新的策略。
  Future<void> onAppResumed() async {
    // 首页首屏尚未完成时，不允许生命周期回调抢先触发更新请求。
    if (!_initialized) return;
    if (_phase == AppUpdatePhase.installing) {
      _phase = AppUpdatePhase.readyToInstall;
      notifyListeners();
      return;
    }
    if (_requiredByApi426) return;
    await check();
  }

  Future<void> deferOptionalUpdate() async {
    if (_requiredByApi426 || _info?.updateType != AppUpdateType.optional) {
      return;
    }
    _phase = AppUpdatePhase.allowed;
    notifyListeners();
  }

  Future<void> ignoreOptionalUpdate() async {
    final info = _info;
    if (_requiredByApi426 ||
        info == null ||
        info.updateType != AppUpdateType.optional) {
      return;
    }
    await _cache.ignoreOptionalVersion(info.latestVersionCode);
    _phase = AppUpdatePhase.allowed;
    notifyListeners();
  }

  /// 下载完成后立即尝试交给系统安装器；若缺少未知来源授权，先跳转系统设置，
  /// 用户返回后可点击“继续安装”，无需重下 APK。
  Future<void> downloadOrInstall() async {
    final info = _info;
    final downloadedApk = _downloadedApk;
    if (downloadedApk != null && await downloadedApk.exists()) {
      final matchesCurrentInfo = info != null &&
          _downloadedVersionCode == info.latestVersionCode &&
          _downloadedSha256 == info.sha256.toLowerCase();
      if (_phase == AppUpdatePhase.readyToInstall || matchesCurrentInfo) {
        await installReadyPackage();
        return;
      }
    } else if (downloadedApk != null) {
      _downloadedApk = null;
      _downloadedVersionCode = null;
      _downloadedSha256 = null;
    }
    if (info == null || !info.updateAvailable || info.downloadUrl.isEmpty) {
      _errorMessage = '更新包信息不完整，请重新检查';
      _phase = isRequired ? AppUpdatePhase.required : AppUpdatePhase.optional;
      notifyListeners();
      return;
    }

    _downloadCancelToken = CancelToken();
    _downloadProgress = null;
    _errorMessage = null;
    _phase = AppUpdatePhase.downloading;
    notifyListeners();
    try {
      _downloadedApk = await _downloadService.download(
        url: info.downloadUrl,
        expectedSize: info.fileSize,
        expectedSha256: info.sha256.toLowerCase(),
        cancelToken: _downloadCancelToken,
        onProgress: (progress) {
          _downloadProgress = progress;
          notifyListeners();
        },
      );
      _downloadedVersionCode = info.latestVersionCode;
      _downloadedSha256 = info.sha256.toLowerCase();
      _phase = AppUpdatePhase.readyToInstall;
      notifyListeners();
      await installReadyPackage();
    } catch (error) {
      _errorMessage = _errorText(error);
      _phase = isRequired ? AppUpdatePhase.required : AppUpdatePhase.optional;
      notifyListeners();
    } finally {
      _downloadCancelToken = null;
    }
  }

  void cancelDownload() {
    _downloadCancelToken?.cancel('用户暂停下载');
  }

  Future<void> installReadyPackage() async {
    final apk = _downloadedApk;
    if (apk == null) return;
    try {
      if (!await _installer.canInstallPackages()) {
        _errorMessage = '请在系统设置中允许“沈理校园”安装未知应用';
        _phase = AppUpdatePhase.readyToInstall;
        notifyListeners();
        await _installer.openInstallPermissionSettings();
        return;
      }
      _errorMessage = null;
      _phase = AppUpdatePhase.installing;
      notifyListeners();
      await _installer.installApk(apk);
    } on PlatformException catch (error) {
      _errorMessage = error.message ?? '无法打开系统安装器';
      _phase = AppUpdatePhase.readyToInstall;
      notifyListeners();
    } catch (error) {
      _errorMessage = _errorText(error);
      _phase = AppUpdatePhase.readyToInstall;
      notifyListeners();
    }
  }

  bool _shouldCheckNow() {
    final checkedAt = _lastSuccessfulCheckAt;
    if (checkedAt == null) return true;
    final seconds = _info?.checkAfterSeconds ?? 300;
    final interval = Duration(seconds: seconds.clamp(60, 86400));
    return DateTime.now().toUtc().difference(checkedAt) >= interval;
  }

  String _errorText(Object error) {
    if (error is AppUpdateApiException || error is AppDownloadError) {
      return error.toString().replaceFirst(RegExp(r'^.*?\): '), '');
    }
    return '更新操作失败: $error';
  }
}

/// 共享 Dio 的 426 拦截器和根级 Provider 共用同一个协调器实例。
final AppUpdateCoordinator appUpdateCoordinator = AppUpdateCoordinator();
