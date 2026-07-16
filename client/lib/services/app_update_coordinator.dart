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
  })  : _api = api ?? AppUpdateApi(),
        _cache = cache ?? AppUpdateCache(),
        _downloadService = downloadService ?? AppUpdateDownloadService(),
        _installer = installer ?? AppInstaller();

  final AppUpdateApi _api;
  final AppUpdateCache _cache;
  final AppUpdateDownloadService _downloadService;
  final AppInstaller _installer;

  AppUpdatePhase _phase = AppUpdatePhase.initializing;
  AppUpdateInfo? _info;
  AppDownloadProgress? _downloadProgress;
  File? _downloadedApk;
  String? _errorMessage;
  DateTime? _lastSuccessfulCheckAt;
  bool _initialized = false;
  bool _checking = false;
  CancelToken? _downloadCancelToken;

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
      _info?.updateType == AppUpdateType.required ||
      _phase == AppUpdatePhase.required;
  bool get isDownloading => _phase == AppUpdatePhase.downloading;
  bool get hasReadyPackage => _phase == AppUpdatePhase.readyToInstall;

  /// 启动时先读取缓存的 required 策略，再联网重验。旧缓存只能收紧门禁，不能
  /// 把新的强制策略降级为可用状态。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _phase = AppUpdatePhase.checking;
    notifyListeners();

    try {
      final headers = await AppVersionHeaders.load();
      final cached = await _cache.read();
      if (cached != null) {
        _lastSuccessfulCheckAt = cached.checkedAt;
        if (cached.info.updateType == AppUpdateType.required &&
            headers.versionCode < cached.info.minimumSupportedVersionCode) {
          _info = cached.info;
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
    if (initial && _phase != AppUpdatePhase.required) {
      _phase = AppUpdatePhase.checking;
      notifyListeners();
    }
    try {
      final headers = await AppVersionHeaders.load();
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
    } catch (error) {
      _errorMessage = _errorText(error);
      // 只有已缓存并仍适用于当前 build 的 required 策略可以在断网时继续拦截。
      // 其余失败默认进入应用，避免临时网络问题阻断本地可用功能。
      if (_phase != AppUpdatePhase.required) {
        _phase = AppUpdatePhase.allowed;
      }
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 业务接口返回 426 时立即进入强制门禁，并后台重拉完整发布信息。
  void requireUpdateFromApi() {
    _phase = AppUpdatePhase.required;
    notifyListeners();
    unawaited(check(force: true));
  }

  /// App 回到前台时调用。若用户从未知来源安装权限页返回，恢复为可点击的
  /// “继续安装”状态；同时按缓存间隔检查是否有新的策略。
  Future<void> onAppResumed() async {
    if (_phase == AppUpdatePhase.installing) {
      _phase = AppUpdatePhase.readyToInstall;
      notifyListeners();
    }
    await check();
  }

  Future<void> deferOptionalUpdate() async {
    if (_info?.updateType != AppUpdateType.optional) return;
    _phase = AppUpdatePhase.allowed;
    notifyListeners();
  }

  Future<void> ignoreOptionalUpdate() async {
    final info = _info;
    if (info == null || info.updateType != AppUpdateType.optional) return;
    await _cache.ignoreOptionalVersion(info.latestVersionCode);
    _phase = AppUpdatePhase.allowed;
    notifyListeners();
  }

  /// 下载完成后立即尝试交给系统安装器；若缺少未知来源授权，先跳转系统设置，
  /// 用户返回后可点击“继续安装”，无需重下 APK。
  Future<void> downloadOrInstall() async {
    if (!AppPlatforms.current.isAndroid) {
      // 鸿蒙不支持 APK 的下载与安装流程。后续接入应用市场或官方分发页前，
      // 保持当前应用可用，避免更新门禁引导用户下载错误格式的安装包。
      _errorMessage = '鸿蒙版请从官方发布渠道获取最新版本';
      _phase = isRequired ? AppUpdatePhase.required : AppUpdatePhase.optional;
      notifyListeners();
      return;
    }
    if (_phase == AppUpdatePhase.readyToInstall && _downloadedApk != null) {
      await installReadyPackage();
      return;
    }
    final info = _info;
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
