import 'dart:async' show unawaited;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';

enum AppBackgroundMode {
  clean,
  custom,
}

enum FrostedGlassPerformanceMode {
  off('关'),
  highPerformance('高性能'),
  highQuality('高画质'),
  custom('自定义');

  const FrostedGlassPerformanceMode(this.label);
  final String label;
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
  off,
  highPerformance,
  highQuality,
  custom,
}

extension BottomNavPerformanceModeStorage on BottomNavPerformanceMode {
  String get storageValue {
    switch (this) {
      case BottomNavPerformanceMode.off:
        return 'off';
      case BottomNavPerformanceMode.highPerformance:
        return 'high_performance';
      case BottomNavPerformanceMode.highQuality:
        return 'high_quality';
      case BottomNavPerformanceMode.custom:
        return 'custom';
    }
  }

  String get label {
    switch (this) {
      case BottomNavPerformanceMode.off:
        return '关';
      case BottomNavPerformanceMode.highPerformance:
        return '高性能';
      case BottomNavPerformanceMode.highQuality:
        return '高画质';
      case BottomNavPerformanceMode.custom:
        return '自定义';
    }
  }

  static BottomNavPerformanceMode fromStorage(String? value) {
    switch (value) {
      case 'high_performance':
        return BottomNavPerformanceMode.highPerformance;
      case 'high_quality':
        return BottomNavPerformanceMode.highQuality;
      case 'custom':
        return BottomNavPerformanceMode.custom;
      default:
        return BottomNavPerformanceMode.off;
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
  static const String _followSystemKey = 'night_mode_follow_system';
  static const String _fontSizePresetKey = 'font_size_preset';
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
      'bottom_nav_performance_mode_v2';
  static const String _bottomNavAnimationIntensityKey =
      'bottom_nav_animation_intensity_v2';
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

  static const bool _defaultPredictiveBack = false;
  static const double _defaultBackgroundBlur = 0.0;
  static const bool _defaultFrostedGlass = false;
  static const double minComponentOpacity = .75;

  static const String _frostedGlassKey = 'frosted_glass_enabled';
  static const String _frostedGlassStrengthKey = 'frosted_glass_strength';
  static const String _frostedGlassCustomStrengthKey =
      'frosted_glass_custom_strength';
  static const String _customComponentOpacityLevelKey =
      'custom_component_opacity_level';

  bool _isLoaded = false;
  bool _isDarkMode = false;
  bool _followSystem = true;
  bool _themeModeChanged = false;
  Future<void>? _themeModeWrites;
  AppFontSizePreset _fontSizePreset = AppFontSizePreset.standard;
  AppBackgroundMode _backgroundMode = AppBackgroundMode.clean;
  String? _backgroundImage;
  String? _landscapeBackgroundImage;
  bool _backgroundFillScreen = false;
  bool _landscapeBackgroundFillScreen = false;
  double _backgroundBlur = _defaultBackgroundBlur;
  double _componentOpacity = 1.0;
  bool _frostedGlass = _defaultFrostedGlass;
  double _frostedGlassStrength = 1.0;
  double _frostedGlassCustomStrength = .65;
  double _customComponentOpacityLevel = .65;
  Future<void>? _cardAppearanceWrites;
  bool _liquidGlass = true;
  bool _floatingNavBar = true;
  BottomNavStyle _bottomNavStyle = BottomNavStyle.liquidGlass;
  BottomNavPerformanceMode _bottomNavPerformanceMode =
      BottomNavPerformanceMode.highQuality;
  double _bottomNavAnimationIntensity = 1.0;
  double _bottomNavCustomIntensity = .65;
  Future<void>? _bottomNavEffectWrites;
  bool _bottomNavClearMaterial = false;
  bool _bottomNavSetupHintDismissed = false;
  bool _bottomNavSetupHintSeen = false;
  bool _bottomNavLiquidGlassConfirmed = false;
  final DevicePerformanceLevel? _performanceLevelOverride;
  bool _predictiveBack = _defaultPredictiveBack;
  bool _startOnTimetable = false;
  StartupDestinationMode _startupDestination = StartupDestinationMode.home;
  bool _marketIsListView = false;

  bool get isLoaded => _isLoaded;

  /// 上次手动选择的明暗偏好；当前生效的策略以 [themeMode] 为准。
  bool get isDarkMode => _isDarkMode;
  bool get followSystem => _followSystem;
  ThemeMode get themeMode => _followSystem
      ? ThemeMode.system
      : (_isDarkMode ? ThemeMode.dark : ThemeMode.light);
  AppFontSizePreset get fontSizePreset => _fontSizePreset;
  AppBackgroundMode get backgroundMode => _backgroundMode;
  bool get isCleanBackgroundMode => _backgroundMode == AppBackgroundMode.clean;
  bool get isCustomBackgroundMode =>
      _backgroundMode == AppBackgroundMode.custom;
  String? get backgroundImage => _backgroundImage;
  String? get landscapeBackgroundImage => _landscapeBackgroundImage;
  bool get backgroundFillScreen => _backgroundFillScreen;
  bool get landscapeBackgroundFillScreen => _landscapeBackgroundFillScreen;
  double get backgroundBlur => _backgroundBlur;
  /// 已保存的不透明度偏好，界面调节使用 [componentOpacityLevel]。
  double get componentOpacity => _componentOpacity;

  /// 调节档位 0–100% 对应实际底色 75–100%，历史偏好按实际底色换算。
  double get componentOpacityLevel => _componentOpacity.isFinite
      ? ((_componentOpacity - minComponentOpacity) / (1 - minComponentOpacity))
          .clamp(0.0, 1.0)
      : 1.0;

  /// 简洁模式使用实色，自定义背景按新的连续调节区间绘制。
  double get effectiveComponentOpacity => shouldShowCustomBackground
      ? minComponentOpacity + (1 - minComponentOpacity) * componentOpacityLevel
      : 1.0;

  // 简洁模式只暂停材质，保留自定义背景下已保存的开关和强度。
  bool get frostedGlass => _frostedGlass && shouldShowCustomBackground;
  double get frostedGlassStrength => _frostedGlassStrength;
  double get frostedGlassCustomStrength => _frostedGlassCustomStrength;
  double get customComponentOpacityLevel => _customComponentOpacityLevel;
  // 固定预设同时约定不透明度和模糊强度，手动值按完整组合重新匹配。
  FrostedGlassPerformanceMode get frostedGlassPerformanceMode {
    if (!shouldShowCustomBackground) return FrostedGlassPerformanceMode.off;
    return switch ((frostedGlass, componentOpacityLevel, _frostedGlassStrength)) {
      (false, 1.0, _) => FrostedGlassPerformanceMode.off,
      (true, .75, .35) => FrostedGlassPerformanceMode.highPerformance,
      (true, 0.0, 1.0) => FrostedGlassPerformanceMode.highQuality,
      _ => FrostedGlassPerformanceMode.custom,
    };
  }
  String get frostedGlassPresetLabel => frostedGlassPerformanceMode.label;
  bool get liquidGlass => _liquidGlass && _bottomNavPerformanceMode != BottomNavPerformanceMode.off;
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
    if (!loadOnStart) return;

    final prewarmed = AppPreferencesStore.maybeInstance;
    if (prewarmed != null) {
      try {
        _applyStoredPreferences(prewarmed);
      } catch (error) {
        debugPrint('同步读取主题本地配置失败，使用默认主题: $error');
      }
      _isLoaded = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
  }

  Future<void> loadThemeForTesting() {
    return _loadTheme();
  }

  BottomNavStyle get bottomNavStyle => _bottomNavPerformanceMode == BottomNavPerformanceMode.off
      ? BottomNavStyle.floating : _bottomNavStyle;
  BottomNavPerformanceMode get bottomNavPerformanceMode =>
      _bottomNavPerformanceMode;
  double get bottomNavAnimationIntensity => _bottomNavAnimationIntensity;
  bool get bottomNavClearMaterial => _bottomNavClearMaterial;
  bool get showBottomNavSetupHint => isLoaded && !_bottomNavSetupHintDismissed && !_bottomNavSetupHintSeen;
  double get bottomNavBlur => _bottomNavClearMaterial ? 0 : 2;
  double? get bottomNavTint => _bottomNavClearMaterial ? .06 : .26;
  DevicePerformanceLevel get devicePerformanceLevel =>
      _performanceLevelOverride ?? DevicePerformanceDetector.current;
  bool get bottomNavLiquidGlassConfirmed => _bottomNavLiquidGlassConfirmed;

  /// 两个液态档位保留折射；关档使用独立的普通悬浮底栏。
  bool get bottomNavShaderEnabled => _bottomNavPerformanceMode != BottomNavPerformanceMode.off;

  double _motionPreset(BottomNavPerformanceMode mode) => switch (mode) {
    BottomNavPerformanceMode.highQuality => 1.0,
    BottomNavPerformanceMode.highPerformance => .35,
    BottomNavPerformanceMode.off => 0.0,
    BottomNavPerformanceMode.custom => _bottomNavCustomIntensity,
  };

  BottomNavPerformanceMode _modeForIntensity(double value) {
    if (value == 0) return BottomNavPerformanceMode.off;
    if ((value - .35).abs() < .0001) return BottomNavPerformanceMode.highPerformance;
    if ((value - 1).abs() < .0001) return BottomNavPerformanceMode.highQuality;
    return BottomNavPerformanceMode.custom;
  }
  Future<void> _loadTheme() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      _applyStoredPreferences(prefs);
    } catch (error) {
      debugPrint('读取主题本地配置失败，使用默认主题: $error');
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  /// 将已初始化偏好应用到内存状态，供同步首帧与异步回退共用。
  void _applyStoredPreferences(AppPreferencesStore prefs) {
    // 初始化晚到时不能覆盖用户刚选的配色模式。
    if (!_themeModeChanged) {
      _isDarkMode = prefs.getBool(_nightModeKey) ?? false;
      _followSystem = prefs.getBool(_followSystemKey) ?? true;
    }
    _fontSizePreset = AppFontSizePreset.fromStorage(
      prefs.getString(_fontSizePresetKey),
    );
    _backgroundImage = prefs.getString(_backgroundImageKey);
    _landscapeBackgroundImage = prefs.getString(_landscapeBackgroundImageKey);
    _backgroundFillScreen = prefs.getBool(_backgroundFillScreenKey) ?? false;
    _landscapeBackgroundFillScreen =
        prefs.getBool(_landscapeBackgroundFillScreenKey) ?? false;
    _backgroundBlur =
        prefs.getDouble(_backgroundBlurKey) ?? _defaultBackgroundBlur;
    _frostedGlass =
        prefs.getBool(_frostedGlassKey) ?? _defaultFrostedGlass;
    _componentOpacity = prefs.getDouble(_componentOpacityKey) ?? 1.0;
    final glassStrength = prefs.getDouble(_frostedGlassStrengthKey) ?? 1.0;
    _frostedGlassStrength = glassStrength.isFinite
        ? glassStrength.clamp(0.0, 1.0)
        : 1.0;
    if (_frostedGlassStrength == 0) _frostedGlass = false;
    final customGlassStrength = prefs.getDouble(_frostedGlassCustomStrengthKey);
    _frostedGlassCustomStrength = customGlassStrength != null &&
            customGlassStrength.isFinite &&
            customGlassStrength > 0 &&
            customGlassStrength <= 1.0
        ? (customGlassStrength * 100).round() / 100
        : .65;
    final customOpacity = prefs.getDouble(_customComponentOpacityLevelKey);
    _customComponentOpacityLevel = customOpacity != null &&
            customOpacity.isFinite &&
            customOpacity >= 0 &&
            customOpacity <= 1.0
        ? (customOpacity * 100).round() / 100
        : .65;
    // 新底栏完整替换旧样式；旧模式/强度不能让升级后的首帧退回旧效果。
    _bottomNavStyle = BottomNavStyle.liquidGlass;
    _liquidGlass = true;
    _floatingNavBar = true;
    final materialMode = prefs.getString(_bottomNavPerformanceModeKey);
    _bottomNavClearMaterial = prefs.getBool('bottom_nav_clear_material') ?? false;
    _bottomNavSetupHintDismissed = prefs.getBool('bottom_nav_setup_hint_dismissed') ?? false;
    _bottomNavSetupHintSeen = prefs.getBool('bottom_nav_setup_hint_seen') ?? false;
    final customIntensity = prefs.getDouble('bottom_nav_custom_intensity') ?? .65;
    _bottomNavCustomIntensity = customIntensity.isFinite && customIntensity > 0
        ? customIntensity.clamp(0.0, 1.0) : .65;
    _bottomNavPerformanceMode = materialMode == null
        ? BottomNavPerformanceMode.highQuality
        : BottomNavPerformanceModeStorage.fromStorage(materialMode);
    _bottomNavAnimationIntensity =
        (prefs.getDouble(_bottomNavAnimationIntensityKey) ?? _motionPreset(_bottomNavPerformanceMode))
            .clamp(0.0, 1.0).toDouble();
    // Repair previously saved mismatched labels without discarding user strength.
    if (_bottomNavPerformanceMode == BottomNavPerformanceMode.off) {
      _bottomNavAnimationIntensity = 0;
    } else {
      _bottomNavPerformanceMode = _modeForIntensity(_bottomNavAnimationIntensity);
      if (_bottomNavPerformanceMode == BottomNavPerformanceMode.custom) {
        _bottomNavCustomIntensity = _bottomNavAnimationIntensity;
      }
    }
    _bottomNavLiquidGlassConfirmed =
        prefs.getBool(_bottomNavLiquidGlassConfirmedKey) ?? false;
    _predictiveBack =
        prefs.getBool(_predictiveBackKey) ?? _defaultPredictiveBack;
    _startOnTimetable = prefs.getBool(_startOnTimetableKey) ?? false;
    _marketIsListView = prefs.getBool(_marketIsListViewKey) ?? false;

    // 旧 start_on_timetable → StartupDestinationMode 一次性迁移。
    StartupDestinationStore.migrateFromLegacySync(prefs);
    _startupDestination = StartupDestinationStore.read(prefs);

    _backgroundMode =
        _backgroundModeFromString(prefs.getString(_backgroundModeKey));

    // 01-04 竖屏预设已下线，旧选择统一回退到黄帽子原图。
    if (_backgroundImage != null &&
        _retiredPhoneWallpaperPattern.hasMatch(_backgroundImage!)) {
      _backgroundImage = _defaultPhoneWallpaper;
      _backgroundFillScreen = false;
      unawaited(prefs.setString(_backgroundImageKey, _defaultPhoneWallpaper));
      unawaited(prefs.setBool(_backgroundFillScreenKey, false));
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

  Future<void> setFollowSystem(bool value) async {
    await setThemeMode(value
        ? ThemeMode.system
        : (_isDarkMode ? ThemeMode.dark : ThemeMode.light));
  }

  Future<void> toggleTheme() async {
    await setDarkMode(!_isDarkMode);
  }

  Future<void> setDarkMode(bool value) async {
    await setThemeMode(value ? ThemeMode.dark : ThemeMode.light);
  }

  Future<bool> setThemeMode(ThemeMode mode) {
    _themeModeChanged = true;
    _followSystem = mode == ThemeMode.system;
    if (!_followSystem) _isDarkMode = mode == ThemeMode.dark;
    final followSystem = _followSystem;
    final darkMode = _isDarkMode;
    notifyListeners();

    // 两个兼容存储字段按选择顺序一起保存，避免快速切换后重启恢复旧模式。
    final write = (_themeModeWrites ?? Future<void>.value()).then((_) async {
      try {
        final prefs = await AppPreferencesStore.getInstance();
        final savedDark = await prefs.setBool(_nightModeKey, darkMode);
        final savedFollow = await prefs.setBool(_followSystemKey, followSystem);
        return savedDark && savedFollow;
      } catch (_) {
        return false;
      }
    });
    _themeModeWrites = write.then((_) {});
    return write;
  }

  Future<void> setFontSizePreset(AppFontSizePreset preset) async {
    if (_fontSizePreset == preset) return;

    _fontSizePreset = preset;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(_fontSizePresetKey, preset.storageValue);
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

  Future<bool> setComponentOpacityLevel(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    final level = (value.clamp(0.0, 1.0) * 100).round() / 100;
    _customComponentOpacityLevel = level;
    return setComponentOpacity(
      minComponentOpacity + (1 - minComponentOpacity) * level,
      updateCustomLevel: false,
    );
  }

  /// 保存底色偏好，界面滑块通过 [setComponentOpacityLevel] 换算后调用。
  Future<bool> setComponentOpacity(double value, {bool updateCustomLevel = true}) {
    if (!value.isFinite) return Future<bool>.value(false);
    final opacity = value.clamp(0.0, 1.0);
    if (updateCustomLevel) {
      final level = ((opacity - minComponentOpacity) / (1 - minComponentOpacity))
          .clamp(0.0, 1.0);
      _customComponentOpacityLevel = (level * 100).round() / 100;
    }
    if (_componentOpacity != opacity) {
      _componentOpacity = opacity;
      notifyListeners();
    }
    final customLevel = _customComponentOpacityLevel;
    return _queueCardAppearanceWrite((prefs) async {
      final results = [
        await prefs.setDouble(_componentOpacityKey, opacity),
        await prefs.setDouble(_customComponentOpacityLevelKey, customLevel),
      ];
      return results.every((saved) => saved);
    });
  }

  Future<void> setBottomNavStyle(BottomNavStyle style) async {
    _bottomNavStyle = BottomNavStyle.liquidGlass;
    _liquidGlass = true;
    _floatingNavBar = true;
    final prefs = await AppPreferencesStore.getInstance();
    await _persistBottomNavPreferences(prefs);
    notifyListeners();
  }

  Future<bool> setBottomNavPerformanceMode(
    BottomNavPerformanceMode mode,
  ) {
    _bottomNavPerformanceMode = mode;
    _bottomNavAnimationIntensity = _motionPreset(mode);
    notifyListeners();
    return _persistBottomNavEffects();
  }

  Future<bool> setBottomNavAnimationIntensity(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    _bottomNavAnimationIntensity = (value.clamp(0.0, 1.0) * 100).round() / 100;
    if (_bottomNavPerformanceMode != BottomNavPerformanceMode.off ||
        _bottomNavAnimationIntensity > 0) {
      _bottomNavPerformanceMode = _modeForIntensity(_bottomNavAnimationIntensity);
      if (_bottomNavPerformanceMode == BottomNavPerformanceMode.custom) {
        _bottomNavCustomIntensity = _bottomNavAnimationIntensity;
      }
    }
    notifyListeners();
    return _persistBottomNavEffects();
  }

  /// 保存调用时的快照，连续拖动及预设切换按顺序落盘，失败可保存当前值重试。
  Future<bool> _persistBottomNavEffects() {
    final mode = _bottomNavPerformanceMode.storageValue;
    final intensity = _bottomNavAnimationIntensity;
    final custom = _bottomNavCustomIntensity;
    final write = (_bottomNavEffectWrites ?? Future<void>.value()).then((_) async {
      try {
        final prefs = await AppPreferencesStore.getInstance();
        final results = [
          await prefs.setString(_bottomNavPerformanceModeKey, mode),
          await prefs.setDouble(_bottomNavAnimationIntensityKey, intensity),
          await prefs.setDouble('bottom_nav_custom_intensity', custom),
        ];
        return results.every((saved) => saved);
      } catch (_) {
        return false;
      }
    });
    _bottomNavEffectWrites = write.then((_) {});
    return write;
  }

  Future<void> setBottomNavClearMaterial(bool value) async {
    _bottomNavClearMaterial = value;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool('bottom_nav_clear_material', value);
    notifyListeners();
  }

  Future<void> dismissBottomNavSetupHint() async {
    _bottomNavSetupHintDismissed = true;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool('bottom_nav_setup_hint_dismissed', true);
    notifyListeners();
  }

  Future<void> markBottomNavSetupHintSeen() async {
    _bottomNavSetupHintSeen = true;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool('bottom_nav_setup_hint_seen', true);
    notifyListeners();
  }

  Future<void> setBottomNavLiquidGlassConfirmed(bool value) async {
    _bottomNavLiquidGlassConfirmed = value;
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool(_bottomNavLiquidGlassConfirmedKey, value);
    notifyListeners();
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

  Future<bool> setFrostedGlass(bool value) {
    final strength = value && _frostedGlassStrength == 0 ? 1.0 : _frostedGlassStrength;
    if (_frostedGlass != value || _frostedGlassStrength != strength) {
      _frostedGlass = value;
      _frostedGlassStrength = strength;
      notifyListeners();
    }
    return _persistFrostedGlass();
  }

  Future<bool> setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode mode) {
    final enabled = mode != FrostedGlassPerformanceMode.off;
    final strength = switch (mode) {
      FrostedGlassPerformanceMode.off => 0.0,
      FrostedGlassPerformanceMode.highPerformance => .35,
      FrostedGlassPerformanceMode.highQuality => 1.0,
      FrostedGlassPerformanceMode.custom => _frostedGlassCustomStrength,
    };
    final opacityLevel = switch (mode) {
      FrostedGlassPerformanceMode.off => 1.0,
      FrostedGlassPerformanceMode.highPerformance => .75,
      FrostedGlassPerformanceMode.highQuality => 0.0,
      FrostedGlassPerformanceMode.custom => _customComponentOpacityLevel,
    };
    final opacity = minComponentOpacity +
        (1 - minComponentOpacity) * opacityLevel;
    if (_frostedGlass != enabled || _frostedGlassStrength != strength ||
        _componentOpacity != opacity) {
      _frostedGlass = enabled;
      _frostedGlassStrength = strength;
      _componentOpacity = opacity;
      notifyListeners();
    }
    return _persistFrostedGlass(includeOpacity: true);
  }

  /// 重试只保存当前数值，不能再次套用预设覆盖用户后续拖动。
  Future<bool> saveFrostedGlassSettings({bool includeOpacity = false}) =>
      _persistFrostedGlass(includeOpacity: includeOpacity);

  /// 拖动时立即预览，按顺序保存，避免较早的异步写入覆盖最终强度。
  /// 同值也允许保存，供存储失败后重试；设置页可从关闭状态向上拖动启用模糊。
  Future<bool> setFrostedGlassStrength(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    final strength = (value.clamp(0.0, 1.0) * 100).round() / 100;
    final enabled = strength > 0;
    final changed = _frostedGlassStrength != strength || _frostedGlass != enabled;
    _frostedGlassStrength = strength;
    _frostedGlass = enabled;
    if (enabled) {
      _frostedGlassCustomStrength = strength;
    }
    if (changed) notifyListeners();
    return _persistFrostedGlass();
  }

  Future<bool> _persistFrostedGlass({bool includeEnabled = true, bool includeOpacity = false}) {
    final enabled = _frostedGlass;
    final strength = _frostedGlassStrength;
    final customStrength = _frostedGlassCustomStrength;
    final customOpacityLevel = _customComponentOpacityLevel;
    final opacity = _componentOpacity;
    return _queueCardAppearanceWrite((prefs) async {
      final results = [
        await prefs.setDouble(_frostedGlassStrengthKey, strength),
        await prefs.setDouble(_frostedGlassCustomStrengthKey, customStrength),
        await prefs.setDouble(_customComponentOpacityLevelKey, customOpacityLevel),
        if (includeEnabled) await prefs.setBool(_frostedGlassKey, enabled),
        if (includeOpacity) await prefs.setDouble(_componentOpacityKey, opacity),
      ];
      return results.every((saved) => saved);
    });
  }

  Future<bool> _queueCardAppearanceWrite(
      Future<bool> Function(AppPreferencesStore) save) {
    final write = (_cardAppearanceWrites ?? Future<void>.value())
        .then((_) async {
      try {
        final prefs = await AppPreferencesStore.getInstance();
        return await save(prefs);
      } catch (_) {
        return false;
      }
    });
    _cardAppearanceWrites = write.then((_) {});
    return write;
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
