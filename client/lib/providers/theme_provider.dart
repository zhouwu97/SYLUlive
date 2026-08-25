import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

enum AppBackgroundMode {
  clean,
  custom,
}

/// 底部导航栏的三种材质层级。
///
/// 液态玻璃是悬浮底栏的增强态，而不是另一套完全独立的导航组件。
enum BottomNavStyle {
  normal,
  floating,
  liquidGlass,
}

extension BottomNavStyleStorage on BottomNavStyle {
  String get storageValue {
    switch (this) {
      case BottomNavStyle.normal:
        return 'normal';
      case BottomNavStyle.floating:
        return 'floating';
      case BottomNavStyle.liquidGlass:
        return 'liquid_glass';
    }
  }

  String get label {
    switch (this) {
      case BottomNavStyle.normal:
        return '标准底栏';
      case BottomNavStyle.floating:
        return '悬浮底栏';
      case BottomNavStyle.liquidGlass:
        return '液态玻璃底栏';
    }
  }

  static BottomNavStyle? fromStorage(String? value) {
    switch (value) {
      case 'normal':
        return BottomNavStyle.normal;
      case 'floating':
        return BottomNavStyle.floating;
      case 'liquid_glass':
      case 'liquidGlass':
        return BottomNavStyle.liquidGlass;
      default:
        return null;
    }
  }
}

enum BottomNavPerformanceMode {
  auto,
  highPerformance,
  highQuality,
}

extension BottomNavPerformanceModeStorage on BottomNavPerformanceMode {
  String get storageValue {
    switch (this) {
      case BottomNavPerformanceMode.auto:
        return 'auto';
      case BottomNavPerformanceMode.highPerformance:
        return 'high_performance';
      case BottomNavPerformanceMode.highQuality:
        return 'high_quality';
    }
  }

  String get label {
    switch (this) {
      case BottomNavPerformanceMode.auto:
        return '自动';
      case BottomNavPerformanceMode.highPerformance:
        return '高性能';
      case BottomNavPerformanceMode.highQuality:
        return '高画质';
    }
  }

  static BottomNavPerformanceMode fromStorage(String? value) {
    switch (value) {
      case 'high_performance':
        return BottomNavPerformanceMode.highPerformance;
      case 'high_quality':
        return BottomNavPerformanceMode.highQuality;
      default:
        return BottomNavPerformanceMode.auto;
    }
  }
}

enum DevicePerformanceLevel {
  low,
  medium,
  high,
}

/// 轻量级设备分级：不读取机型数据库，也不把 shader 当作所有设备默认能力。
///
/// 机型识别不可用时使用 CPU 核数作为保守启发式；最终仍由渲染器探测负责
/// shader fallback。该类保持纯函数入口，便于在测试中验证边界。
abstract final class DevicePerformanceDetector {
  static DevicePerformanceLevel get current => fromProcessorCount(
        Platform.numberOfProcessors,
        isMobile: Platform.isAndroid || Platform.isIOS,
      );

  static DevicePerformanceLevel fromProcessorCount(
    int processorCount, {
    bool isMobile = false,
  }) {
    if (processorCount <= (isMobile ? 4 : 2)) {
      return DevicePerformanceLevel.low;
    }
    if (processorCount >= (isMobile ? 8 : 6)) {
      return DevicePerformanceLevel.high;
    }
    return DevicePerformanceLevel.medium;
  }

  static BottomNavStyle defaultStyleFor(DevicePerformanceLevel level) {
    return level == DevicePerformanceLevel.low
        ? BottomNavStyle.normal
        : BottomNavStyle.floating;
  }
}

/// 简洁模式（clean mode）下的暖色底色规范。
///
/// 亮色：页面底用暖白，卡片保持纯白，卡片边框用青灰。
/// 暗色：深色表面遵循全局 Token。
const Color kCleanWarmBackgroundLight = Color(0xFFFFFAF4);
const Color kCleanWarmCardBorderLight = Color(0xFFE2EFEA);
const Color kCleanWarmBackgroundDark = Color(0xFF111315);

class ThemeProvider extends ChangeNotifier {
  static const String _nightModeKey = 'night_mode';
  static const String _backgroundModeKey = 'background_mode';
  static const String _backgroundImageKey = 'background_image';
  static const String _landscapeBackgroundImageKey =
      'landscape_background_image';
  static const String _backgroundFillScreenKey = 'background_fill_screen';
  static const String _landscapeBackgroundFillScreenKey =
      'landscape_background_fill_screen';
  static const String _backgroundBlurKey = 'background_blur';
  static const String _componentOpacityKey =
      'background_transparency'; // 保持 key 兼容
  static const String _liquidGlassKey = 'liquid_glass_v2';
  static const String _floatingNavBarKey = 'floating_nav_bar';
  // 新导航配置的稳定 key；旧 key 仍同步写入，保证升级不丢设置。
  static const String _bottomNavStyleKey = 'bottom_nav_style';
  static const String _bottomNavPerformanceModeKey =
      'bottom_nav_performance_mode';
  static const String _bottomNavAnimationIntensityKey =
      'bottom_nav_animation_intensity';
  static const String _bottomNavFloatingKey = 'floating_nav';
  static const String _bottomNavLiquidGlassKey = 'liquid_glass';
  static const String _bottomNavLiquidGlassConfirmedKey =
      'bottom_nav_liquid_glass_confirmed';
  static const String _predictiveBackKey = 'predictive_back_enabled';
  static const String _startOnTimetableKey = 'start_on_timetable';
  static const String _marketIsListViewKey = 'market_is_list_view';
  static final RegExp _retiredPhoneWallpaperPattern = RegExp(
    r'(^|[\\/])(?:remote_)?phone_wallpaper_0[1-4]\.(?:png|jpe?g)(?:[?#].*)?$',
    caseSensitive: false,
  );
  static const String _defaultPhoneWallpaper = 'morenbeijing.jpeg';

  bool _isLoaded = false;
  bool _isDarkMode = false;
  AppBackgroundMode _backgroundMode = AppBackgroundMode.clean;
  String? _backgroundImage;
  String? _landscapeBackgroundImage;
  bool _backgroundFillScreen = false;
  bool _landscapeBackgroundFillScreen = false;
  double _backgroundBlur = 10;
  double _componentOpacity = 0.7;
  bool _liquidGlass = false;
  bool _floatingNavBar = true;
  BottomNavStyle _bottomNavStyle = BottomNavStyle.floating;
  BottomNavPerformanceMode _bottomNavPerformanceMode =
      BottomNavPerformanceMode.auto;
  double _bottomNavAnimationIntensity = 0.65;
  bool _bottomNavLiquidGlassConfirmed = false;
  final DevicePerformanceLevel? _performanceLevelOverride;
  bool _predictiveBack = true;
  bool _startOnTimetable = false;
  StartupDestinationMode _startupDestination = StartupDestinationMode.home;
  bool _marketIsListView = false;

  bool get isLoaded => _isLoaded;
  bool get isDarkMode => _isDarkMode;
  AppBackgroundMode get backgroundMode => _backgroundMode;
  bool get isCleanBackgroundMode => _backgroundMode == AppBackgroundMode.clean;
  bool get isCustomBackgroundMode =>
      _backgroundMode == AppBackgroundMode.custom;
  String? get backgroundImage => _backgroundImage;
  String? get landscapeBackgroundImage => _landscapeBackgroundImage;
  bool get backgroundFillScreen => _backgroundFillScreen;
  bool get landscapeBackgroundFillScreen => _landscapeBackgroundFillScreen;
  double get backgroundBlur => _backgroundBlur;
  double get componentOpacity => _componentOpacity;
  bool get liquidGlass => _liquidGlass;
  bool get floatingNavBar => _floatingNavBar;
  bool get predictiveBack => _predictiveBack;

  /// 旧字段，保留一个版本供外部代码过渡。不再作为导航决策数据源。
  bool get startOnTimetable => _startOnTimetable;

  /// 统一启动目标模式，替代旧 [startOnTimetable]。
  StartupDestinationMode get startupDestination => _startupDestination;
  bool get marketIsListView => _marketIsListView;

  bool get hasBackground =>
      _backgroundImage != null && _backgroundImage!.isNotEmpty;
  bool get hasLandscapeBackground =>
      _landscapeBackgroundImage != null &&
      _landscapeBackgroundImage!.isNotEmpty;
  bool get hasAnyBackground => hasBackground || hasLandscapeBackground;

  bool get shouldShowCustomBackground =>
      isCustomBackgroundMode && hasAnyBackground;

  static bool isBundledAssetBackground(String imagePath) {
    return !imagePath.startsWith('/') &&
        !imagePath.startsWith('file://') &&
        !imagePath.startsWith('http://') &&
        !imagePath.startsWith('https://');
  }

  static bool isLocalFileBackground(String imagePath) {
    return imagePath.startsWith('/') || imagePath.startsWith('file://');
  }

  static String resolveBundledAssetPath(String assetName) {
    if (assetName.startsWith('assets/')) return assetName;
    return 'assets/images/$assetName';
  }

  /// 安全性辅助方法：仅在 Provider 状态与 Preferences Store 更新成功后，异步清理存放在应用受管壁纸目录下的旧本地孤儿壁纸
  static Future<void> _tryDeleteLocalManagedFile(String? filePath) async {
    if (filePath == null || !isLocalFileBackground(filePath)) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final customDir = path.join(appDir.path, 'wallpapers', 'custom');
      final normalizedFile = path.normalize(filePath);
      final normalizedRoot = path.normalize(customDir);

      final file = File(filePath);
      final fileName = path.basename(filePath);

      final isManagedName = fileName.startsWith('background_') ||
          fileName.startsWith('landscape_background_');
      final isManagedPath = path.isWithin(normalizedRoot, normalizedFile);

      if (isManagedName || isManagedPath) {
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {}
  }

  /// 获取自定义模式下当前环境适用的背景图；当前方向缺失时使用另一方向兜底。
  String? getCustomBackgroundImageFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide) {
      return hasLandscapeBackground
          ? _landscapeBackgroundImage
          : _backgroundImage;
    }
    return hasBackground ? _backgroundImage : _landscapeBackgroundImage;
  }

  bool getCustomBackgroundFillScreenFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide) {
      return hasLandscapeBackground
          ? _landscapeBackgroundFillScreen
          : _backgroundFillScreen;
    }
    return hasBackground
        ? _backgroundFillScreen
        : _landscapeBackgroundFillScreen;
  }

  ThemeProvider({
    bool loadOnStart = true,
    DevicePerformanceLevel? performanceLevel,
  }) : _performanceLevelOverride = performanceLevel {
    if (loadOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
    }
  }

  Future<void> loadThemeForTesting() {
    return _loadTheme();
  }

  BottomNavStyle get bottomNavStyle => _bottomNavStyle;
  BottomNavPerformanceMode get bottomNavPerformanceMode =>
      _bottomNavPerformanceMode;
  double get bottomNavAnimationIntensity => _bottomNavAnimationIntensity;
  DevicePerformanceLevel get devicePerformanceLevel =>
      _performanceLevelOverride ?? DevicePerformanceDetector.current;
  bool get bottomNavLiquidGlassConfirmed => _bottomNavLiquidGlassConfirmed;

  /// 自动模式只让高性能设备尝试 shader；中端设备保留 blur，低端设备的
  /// 默认样式由 [DevicePerformanceDetector.defaultStyleFor] 降为普通底栏。
  bool get bottomNavShaderEnabled {
    if (_bottomNavStyle != BottomNavStyle.liquidGlass) return false;
    switch (_bottomNavPerformanceMode) {
      case BottomNavPerformanceMode.auto:
        return devicePerformanceLevel == DevicePerformanceLevel.high;
      case BottomNavPerformanceMode.highPerformance:
        return false;
      case BottomNavPerformanceMode.highQuality:
        return true;
    }
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      _isDarkMode = prefs.getBool(_nightModeKey) ?? false;
      _backgroundImage = prefs.getString(_backgroundImageKey);
      _landscapeBackgroundImage = prefs.getString(_landscapeBackgroundImageKey);
      _backgroundFillScreen = prefs.getBool(_backgroundFillScreenKey) ?? false;
      _landscapeBackgroundFillScreen =
          prefs.getBool(_landscapeBackgroundFillScreenKey) ?? false;
      _backgroundBlur = prefs.getDouble(_backgroundBlurKey) ?? 10;
      _componentOpacity = prefs.getDouble(_componentOpacityKey) ?? 0.7;
      final storedStyle = BottomNavStyleStorage.fromStorage(
        prefs.getString(_bottomNavStyleKey),
      );
      final legacyFloating = prefs.getBool(_bottomNavFloatingKey) ??
          prefs.getBool(_floatingNavBarKey);
      final legacyLiquid = prefs.getBool(_bottomNavLiquidGlassKey) ??
          prefs.getBool(_liquidGlassKey) ??
          false;
      _bottomNavStyle = storedStyle ??
          (legacyLiquid
              ? BottomNavStyle.liquidGlass
              : legacyFloating == false
                  ? BottomNavStyle.normal
                  : legacyFloating == true
                      ? BottomNavStyle.floating
                      : DevicePerformanceDetector.defaultStyleFor(
                          devicePerformanceLevel,
                        ));
      _liquidGlass = _bottomNavStyle == BottomNavStyle.liquidGlass;
      _floatingNavBar = _bottomNavStyle != BottomNavStyle.normal;
      _bottomNavPerformanceMode = BottomNavPerformanceModeStorage.fromStorage(
        prefs.getString(_bottomNavPerformanceModeKey),
      );
      _bottomNavAnimationIntensity =
          (prefs.getDouble(_bottomNavAnimationIntensityKey) ?? 0.65)
              .clamp(0.0, 1.0)
              .toDouble();
      _bottomNavLiquidGlassConfirmed =
          prefs.getBool(_bottomNavLiquidGlassConfirmedKey) ?? false;
      _predictiveBack = prefs.getBool(_predictiveBackKey) ?? true;
      _startOnTimetable = prefs.getBool(_startOnTimetableKey) ?? false;
      _marketIsListView = prefs.getBool(_marketIsListViewKey) ?? false;

      // 旧 start_on_timetable → StartupDestinationMode 一次性迁移。
      await StartupDestinationStore.migrateFromLegacy(prefs);
      _startupDestination = StartupDestinationStore.read(prefs);

      _backgroundMode =
          _backgroundModeFromString(prefs.getString(_backgroundModeKey));

      // 01-04 竖屏预设已下线，旧选择统一回退到黄帽子原图。
      if (_backgroundImage != null &&
          _retiredPhoneWallpaperPattern.hasMatch(_backgroundImage!)) {
        _backgroundImage = _defaultPhoneWallpaper;
        _backgroundFillScreen = false;
        await prefs.setString(_backgroundImageKey, _defaultPhoneWallpaper);
        await prefs.setBool(_backgroundFillScreenKey, false);
      }
    } catch (error) {
      debugPrint('读取主题本地配置失败，使用默认主题: $error');
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _setBackgroundMode(AppBackgroundMode mode) async {
    _backgroundMode = mode;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(_backgroundModeKey, _backgroundModeToString(mode));
    notifyListeners();
  }

  Future<void> setCleanBackgroundMode() async {
    await _setBackgroundMode(AppBackgroundMode.clean);
  }

  Future<bool> trySetCustomBackgroundMode() async {
    if (!hasAnyBackground) return false;
    await _setBackgroundMode(AppBackgroundMode.custom);
    return true;
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_nightModeKey, _isDarkMode);
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    _isDarkMode = value;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_nightModeKey, value);
    notifyListeners();
  }

  Future<void> setBackgroundImage(
    String? imageUrl, {
    bool fillScreen = false,
  }) async {
    final oldPath = _backgroundImage;
    _backgroundImage = imageUrl;
    _backgroundFillScreen =
        imageUrl != null && imageUrl.isNotEmpty ? fillScreen : false;
    final prefs = await AppPreferencesStore.getInstance();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      await prefs.setString(_backgroundImageKey, imageUrl);
      await prefs.setBool(_backgroundFillScreenKey, _backgroundFillScreen);
      _backgroundMode = AppBackgroundMode.custom;
      await prefs.setString(
        _backgroundModeKey,
        _backgroundModeToString(_backgroundMode),
      );
    } else {
      await prefs.remove(_backgroundImageKey);
      await prefs.remove(_backgroundFillScreenKey);
    }
    notifyListeners();

    if (oldPath != imageUrl) {
      await _tryDeleteLocalManagedFile(oldPath);
    }
  }

  Future<void> setLandscapeBackgroundImage(
    String? imageUrl, {
    bool fillScreen = false,
  }) async {
    final oldPath = _landscapeBackgroundImage;
    _landscapeBackgroundImage = imageUrl;
    _landscapeBackgroundFillScreen =
        imageUrl != null && imageUrl.isNotEmpty ? fillScreen : false;
    final prefs = await AppPreferencesStore.getInstance();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      await prefs.setString(_landscapeBackgroundImageKey, imageUrl);
      await prefs.setBool(
        _landscapeBackgroundFillScreenKey,
        _landscapeBackgroundFillScreen,
      );
      _backgroundMode = AppBackgroundMode.custom;
      await prefs.setString(
        _backgroundModeKey,
        _backgroundModeToString(_backgroundMode),
      );
    } else {
      await prefs.remove(_landscapeBackgroundImageKey);
      await prefs.remove(_landscapeBackgroundFillScreenKey);
    }
    notifyListeners();

    if (oldPath != imageUrl) {
      await _tryDeleteLocalManagedFile(oldPath);
    }
  }

  Future<void> setBackgroundBlur(double blur) async {
    _backgroundBlur = blur.clamp(0, 30);
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setDouble(_backgroundBlurKey, _backgroundBlur);
    notifyListeners();
  }

  Future<void> setComponentOpacity(double value) async {
    _componentOpacity = value.clamp(0.0, 1.0);
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setDouble(_componentOpacityKey, _componentOpacity);
    notifyListeners();
  }

  Future<void> setBottomNavStyle(BottomNavStyle style) async {
    _bottomNavStyle = style;
    _liquidGlass = style == BottomNavStyle.liquidGlass;
    _floatingNavBar = style != BottomNavStyle.normal;
    final prefs = await AppPreferencesStore.getInstance();
    await _persistBottomNavPreferences(prefs);
    notifyListeners();
  }

  Future<void> setBottomNavPerformanceMode(
    BottomNavPerformanceMode mode,
  ) async {
    _bottomNavPerformanceMode = mode;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(_bottomNavPerformanceModeKey, mode.storageValue);
    notifyListeners();
  }

  Future<void> setBottomNavAnimationIntensity(double value) async {
    _bottomNavAnimationIntensity = value.clamp(0.0, 1.0).toDouble();
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setDouble(
      _bottomNavAnimationIntensityKey,
      _bottomNavAnimationIntensity,
    );
    notifyListeners();
  }

  Future<void> setBottomNavLiquidGlassConfirmed(bool value) async {
    _bottomNavLiquidGlassConfirmed = value;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_bottomNavLiquidGlassConfirmedKey, value);
    notifyListeners();
  }

  Future<void> setLiquidGlass(bool value) async {
    await setBottomNavStyle(
      value
          ? BottomNavStyle.liquidGlass
          : (_floatingNavBar ? BottomNavStyle.floating : BottomNavStyle.normal),
    );
  }

  Future<void> setFloatingNavBar(bool value) async {
    await setBottomNavStyle(
      value
          ? (_liquidGlass
              ? BottomNavStyle.liquidGlass
              : BottomNavStyle.floating)
          : BottomNavStyle.normal,
    );
  }

  Future<void> _persistBottomNavPreferences(AppPreferencesStore prefs) async {
    await prefs.setString(_bottomNavStyleKey, _bottomNavStyle.storageValue);
    await prefs.setBool(_bottomNavFloatingKey, _floatingNavBar);
    await prefs.setBool(_bottomNavLiquidGlassKey, _liquidGlass);
    await prefs.setBool(_floatingNavBarKey, _floatingNavBar);
    await prefs.setBool(_liquidGlassKey, _liquidGlass);
  }

  Future<void> setPredictiveBack(bool value) async {
    _predictiveBack = value;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_predictiveBackKey, value);
    notifyListeners();
  }

  Future<void> clearBackground() async {
    final oldPortrait = _backgroundImage;
    final oldLandscape = _landscapeBackgroundImage;

    _backgroundImage = null;
    _landscapeBackgroundImage = null;
    _backgroundFillScreen = false;
    _landscapeBackgroundFillScreen = false;
    _backgroundMode = AppBackgroundMode.clean;

    final prefs = await AppPreferencesStore.getInstance();
    await prefs.remove(_backgroundImageKey);
    await prefs.remove(_landscapeBackgroundImageKey);
    await prefs.remove(_backgroundFillScreenKey);
    await prefs.remove(_landscapeBackgroundFillScreenKey);
    await prefs.setString(
      _backgroundModeKey,
      _backgroundModeToString(_backgroundMode),
    );
    notifyListeners();

    await _tryDeleteLocalManagedFile(oldPortrait);
    await _tryDeleteLocalManagedFile(oldLandscape);
  }

  /// 旧方法，仅保留兼容签名。内部同步写新 key。
  Future<void> setStartOnTimetable(bool v) async {
    _startOnTimetable = v;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_startOnTimetableKey, v);
    // 同步新 key，保持一致。
    final mode =
        v ? StartupDestinationMode.timetable : StartupDestinationMode.home;
    _startupDestination = mode;
    await StartupDestinationStore.write(prefs, mode);
    notifyListeners();
  }

  /// 设置统一启动目标模式。
  Future<void> setStartupDestination(StartupDestinationMode mode) async {
    _startupDestination = mode;
    final prefs = await AppPreferencesStore.getInstance();
    await StartupDestinationStore.write(prefs, mode);
    // 同步旧 key（过渡期兼容）。
    _startOnTimetable = mode == StartupDestinationMode.timetable;
    await prefs.setBool(_startOnTimetableKey, _startOnTimetable);
    // 切换模式时丢弃上次保存的页面，避免历史垃圾状态在日后切回 lastPage 时复活。
    await RootPageStateStore.instance.clearLastPage();
    notifyListeners();
  }

  Future<void> setMarketIsListView(bool v) async {
    _marketIsListView = v;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_marketIsListViewKey, v);
    notifyListeners();
  }

  static AppBackgroundMode _backgroundModeFromString(String? value) {
    if (value == 'custom') return AppBackgroundMode.custom;
    return AppBackgroundMode.clean;
  }

  static String _backgroundModeToString(AppBackgroundMode mode) {
    return mode == AppBackgroundMode.custom ? 'custom' : 'clean';
  }
}
