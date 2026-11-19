import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as path;
import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/home_widget_service.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';
import '../features/theme_pack/launcher_icon_service.dart';
import '../features/theme_pack/theme_appearance.dart';
import '../features/theme_pack/theme_appearance_exporter.dart';
import '../features/theme_pack/theme_font_registry.dart';
import '../features/theme_pack/theme_manifest.dart';
import '../features/theme_pack/theme_pack_codec.dart';
import '../features/theme_pack/theme_pack_store.dart';
import '../features/theme_pack/theme_trial_banner.dart';
import '../utils/app_navigator.dart';

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

extension FrostedGlassPerformanceModeStorage on FrostedGlassPerformanceMode {
  String get storageValue {
    switch (this) {
      case FrostedGlassPerformanceMode.off:
        return 'off';
      case FrostedGlassPerformanceMode.highPerformance:
        return 'high_performance';
      case FrostedGlassPerformanceMode.highQuality:
        return 'high_quality';
      case FrostedGlassPerformanceMode.custom:
        return 'custom';
    }
  }

  static FrostedGlassPerformanceMode fromStorage(String? value) {
    switch (value) {
      case 'high_performance':
        return FrostedGlassPerformanceMode.highPerformance;
      case 'high_quality':
        return FrostedGlassPerformanceMode.highQuality;
      case 'custom':
        return FrostedGlassPerformanceMode.custom;
      default:
        return FrostedGlassPerformanceMode.off;
    }
  }
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

class ThemeTrialSession {
  const ThemeTrialSession({
    required this.manifest,
    required this.groups,
    required this.appearance,
    this.installed,
    this.pack,
    this.stagingDirectory,
  });

  final ThemeManifest manifest;
  final Set<ThemeGroup> groups;
  final ThemeAppearance appearance;
  final InstalledTheme? installed;
  final PreparedThemePack? pack;
  final String? stagingDirectory;
}

class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static const appearanceKey = 'theme_appearance_v1';
  static const previousAppearanceKey = 'theme_previous_v1';
  final ThemePackStore themePacks;
  ThemeAppearance _appearance = const ThemeAppearance.empty();
  ThemeAppearance? _previousAppearance;
  ThemeTrialSession? _trial;
  int _trialGeneration = 0;
  bool _appearanceLoaded = false;
  bool _themeFilesInitialized = false;
  bool _disposed = false;
  String? _themeStorageWarning;
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
  static const String _frostedGlassPerformanceModeKey =
      'frosted_glass_performance_mode';
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
  FrostedGlassPerformanceMode _frostedGlassPerformanceMode =
      FrostedGlassPerformanceMode.off;
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
  AppBackgroundMode get backgroundMode => usesThemeWallpapers
      ? (themeWallpaper == null
          ? AppBackgroundMode.clean
          : AppBackgroundMode.custom)
      : _legacyWallpaper == null
          ? _backgroundMode
          : AppBackgroundMode.values
              .byName(_legacyWallpaper!['mode'] as String);
  bool get isCleanBackgroundMode => backgroundMode == AppBackgroundMode.clean;
  bool get isCustomBackgroundMode => backgroundMode == AppBackgroundMode.custom;
  String? get backgroundImage => usesThemeWallpapers
      ? (themeWallpaper?['portrait'] as String?)
      : _legacyWallpaper == null
          ? _backgroundImage
          : _legacyWallpaper!['portrait'] as String?;
  String? get landscapeBackgroundImage => usesThemeWallpapers
      ? (themeWallpaper?['landscape'] as String?)
      : _legacyWallpaper == null
          ? _landscapeBackgroundImage
          : _legacyWallpaper!['landscape'] as String?;
  bool get backgroundFillScreen => usesThemeWallpapers
      ? (themeWallpaper?['fit'] == 'cover')
      : _legacyWallpaper == null
          ? _backgroundFillScreen
          : _legacyWallpaper!['portraitFill'] as bool;
  bool get landscapeBackgroundFillScreen => usesThemeWallpapers
      ? backgroundFillScreen
      : _legacyWallpaper == null
          ? _landscapeBackgroundFillScreen
          : _legacyWallpaper!['landscapeFill'] as bool;
  double get backgroundBlur => usesThemeWallpapers
      ? (themeWallpaper?['blur'] as num? ?? 0).toDouble()
      : _legacyWallpaper == null
          ? _backgroundBlur
          : (_legacyWallpaper!['blur'] as num).toDouble();

  /// 已保存的不透明度偏好，界面调节使用 [componentOpacityLevel]。
  double get componentOpacity =>
      (_activeMaterial?['componentOpacity'] as num?)?.toDouble() ??
      _componentOpacity;

  /// 调节档位 0–100% 对应实际底色 75–100%，历史偏好按实际底色换算。
  double get componentOpacityLevel => componentOpacity.isFinite
      ? ((componentOpacity - minComponentOpacity) / (1 - minComponentOpacity))
          .clamp(0.0, 1.0)
      : 1.0;

  /// 显式主题材质按变体绘制；原手动材质仅在自定义背景下生效。
  double get effectiveComponentOpacity =>
      _materialGroup != null && _materialGroup!['legacy'] != true
          ? componentOpacity.clamp(minComponentOpacity, 1.0)
          : shouldShowCustomBackground
              ? minComponentOpacity +
                  (1 - minComponentOpacity) * componentOpacityLevel
              : 1.0;

  // 简洁模式只暂停材质，保留自定义背景下已保存的开关和强度。
  bool get frostedGlass => _activeMaterial == null
      ? _frostedGlass && shouldShowCustomBackground
      : _activeMaterial!['frostedGlass']['enabled'] as bool &&
          (_materialGroup!['legacy'] != true || shouldShowCustomBackground);
  double get frostedGlassStrength =>
      (_activeMaterial?['frostedGlass']['strength'] as num?)?.toDouble() ??
      _frostedGlassStrength;
  double get frostedGlassCustomStrength => _frostedGlassCustomStrength;
  double get customComponentOpacityLevel => _customComponentOpacityLevel;
  FrostedGlassPerformanceMode get frostedGlassPerformanceMode =>
      !canCustomizeCardMaterial
          ? FrostedGlassPerformanceMode.off
          : _activeMaterial == null
              ? _frostedGlassPerformanceMode
              : _modeForFrostedGlass(frostedGlass ? frostedGlassStrength : 0,
                  componentOpacityLevel);
  String get frostedGlassPresetLabel => frostedGlassPerformanceMode.label;
  bool get liquidGlass => _navigationGroup?['style'] != null
      ? bottomNavStyle == BottomNavStyle.liquidGlass
      : _liquidGlass &&
          bottomNavPerformanceMode != BottomNavPerformanceMode.off;
  bool get floatingNavBar => _navigationGroup?['style'] != null
      ? bottomNavStyle != BottomNavStyle.normal
      : _floatingNavBar;
  bool get predictiveBack => _predictiveBack;

  /// 旧字段，保留一个版本供外部代码过渡。不再作为导航决策数据源。
  bool get startOnTimetable => _startOnTimetable;

  /// 统一启动目标模式，替代旧 [startOnTimetable]。
  StartupDestinationMode get startupDestination => _startupDestination;
  bool get marketIsListView => _marketIsListView;

  bool get hasBackground =>
      backgroundImage != null && backgroundImage!.isNotEmpty;
  bool get hasLandscapeBackground =>
      landscapeBackgroundImage != null && landscapeBackgroundImage!.isNotEmpty;
  bool get hasAnyBackground => hasBackground || hasLandscapeBackground;

  /// 正在显示壁纸图片。不少页面据此把顶栏文字改成白色，所以氛围背景不计入。
  bool get shouldShowCustomBackground => isCustomBackgroundMode && hasAnyBackground;

  /// 用户自选照片壁纸：顶栏需要压暗并改用白字。主题壁纸和主题配色一起设计，不需要。
  bool get needsPhotoContrast =>
      shouldShowCustomBackground && !usesThemeWallpapers;

  /// 页面需要透明、露出背景层：壁纸图片或主题氛围背景。
  bool get hasSeeThroughBackground =>
      shouldShowCustomBackground || themeBackdrop != null;

  /// 当前明暗模式的氛围背景（渐变、光斑、纹理）。
  Map<String, dynamic>? get themeBackdrop {
    if (!usesThemeWallpapers) return null;
    final mode = _wallpaperGroup![_appearanceMode] as Map?;
    return mode?['backdrop'] as Map<String, dynamic>?;
  }

  /// 当前外观在 [slot]（home / campus / me）使用沉浸页头且有页头图片或贴纸。
  /// 主壳这三个页面此时必须保持透明，hero 画在它们下面的背景层里。
  bool hasImmersiveHero(String slot) {
    final layout = appearance.group(ThemeGroup.layout)?['value'] as Map?;
    final header = layout?[slot] as Map?;
    if (header?['preset'] != 'immersive') return false;
    final decoration =
        (appearance.group(ThemeGroup.decoration)?[_appearanceMode] as Map?)?[
            slot] as Map?;
    final stickers = decoration?['stickers'] as List?;
    return decoration?['background'] != null ||
        (stickers != null && stickers.isNotEmpty);
  }

  static bool isBundledAssetBackground(String imagePath) {
    return !isLocalFileBackground(imagePath) &&
        !imagePath.startsWith('http://') &&
        !imagePath.startsWith('https://');
  }

  static bool isLocalFileBackground(String imagePath) {
    return imagePath.startsWith('/') ||
        imagePath.startsWith('file://') ||
        path.isAbsolute(imagePath);
  }

  static String resolveBundledAssetPath(String assetName) {
    if (assetName.startsWith('assets/')) return assetName;
    return 'assets/images/$assetName';
  }

  /// 获取自定义模式下当前环境适用的背景图；当前方向缺失时使用另一方向兜底。
  String? getCustomBackgroundImageFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide) {
      return hasLandscapeBackground
          ? landscapeBackgroundImage
          : backgroundImage;
    }
    return hasBackground ? backgroundImage : landscapeBackgroundImage;
  }

  bool getCustomBackgroundFillScreenFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide) {
      return hasLandscapeBackground
          ? landscapeBackgroundFillScreen
          : backgroundFillScreen;
    }
    return hasBackground ? backgroundFillScreen : landscapeBackgroundFillScreen;
  }

  ThemeProvider({
    bool loadOnStart = true,
    DevicePerformanceLevel? performanceLevel,
    ThemePackStore? themePackStore,
  })  : themePacks = themePackStore ?? const ThemePackStore(),
        _performanceLevelOverride = performanceLevel {
    WidgetsBinding.instance.addObserver(this);
    currentHomeTabIndex.addListener(_onThemeTabChanged);
    if (!loadOnStart) return;

    final prewarmed = AppPreferencesStore.maybeInstance;
    if (prewarmed != null) {
      try {
        _applyStoredPreferences(prewarmed);
      } catch (error) {
        debugPrint('同步读取主题本地配置失败，使用默认主题: $error');
      }
      _isLoaded = true;
      _startThemeFileMaintenance();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
  }

  Future<void> loadThemeForTesting() {
    return _loadTheme();
  }

  BottomNavStyle get bottomNavStyle => _navigationGroup?['style'] != null
      ? BottomNavStyleStorage.fromStorage(_navigationGroup!['style'] as String)!
      : bottomNavPerformanceMode == BottomNavPerformanceMode.off
          ? BottomNavStyle.floating
          : _bottomNavStyle;
  BottomNavPerformanceMode get bottomNavPerformanceMode => _navigationMotion ==
          null
      ? _bottomNavPerformanceMode
      : BottomNavPerformanceModeStorage.fromStorage(
          _navigationMotion!['performanceMode'] as String);
  double get bottomNavAnimationIntensity =>
      (_navigationMotion?['intensity'] as num?)?.toDouble() ??
      _bottomNavAnimationIntensity;
  bool get bottomNavClearMaterial =>
      _navigationMotion?['clearMaterial'] as bool? ?? _bottomNavClearMaterial;
  bool get showBottomNavSetupHint =>
      isLoaded && !_bottomNavSetupHintDismissed && !_bottomNavSetupHintSeen;
  double get bottomNavBlur => bottomNavClearMaterial ? 0 : 2;
  double? get bottomNavTint => bottomNavClearMaterial ? .06 : .26;
  DevicePerformanceLevel get devicePerformanceLevel =>
      _performanceLevelOverride ?? DevicePerformanceDetector.current;
  bool get bottomNavLiquidGlassConfirmed => _bottomNavLiquidGlassConfirmed;

  /// 两个液态档位保留折射；关档使用独立的普通悬浮底栏。
  bool get bottomNavShaderEnabled =>
      bottomNavPerformanceMode != BottomNavPerformanceMode.off;

  double _motionPreset(BottomNavPerformanceMode mode) => switch (mode) {
    BottomNavPerformanceMode.highQuality => 1.0,
    BottomNavPerformanceMode.highPerformance => .35,
    BottomNavPerformanceMode.off => 0.0,
    BottomNavPerformanceMode.custom => _bottomNavCustomIntensity,
  };

  BottomNavPerformanceMode _modeForIntensity(double value) {
    if (value == 0) return BottomNavPerformanceMode.off;
    if ((value - .35).abs() < .0001) {
      return BottomNavPerformanceMode.highPerformance;
    }
    if ((value - 1).abs() < .0001) return BottomNavPerformanceMode.highQuality;
    return BottomNavPerformanceMode.custom;
  }

  static double _roundPercent(double value) => (value * 100).round() / 100;

  (double, double) _frostedGlassPreset(FrostedGlassPerformanceMode mode) =>
      switch (mode) {
        FrostedGlassPerformanceMode.off => (0.0, 1.0),
        FrostedGlassPerformanceMode.highPerformance => (.35, .75),
        FrostedGlassPerformanceMode.highQuality => (1.0, 0.0),
        FrostedGlassPerformanceMode.custom => (
            _frostedGlassCustomStrength,
            _customComponentOpacityLevel,
          ),
      };

  FrostedGlassPerformanceMode _modeForFrostedGlass(
    double strength,
    double opacityLevel,
  ) {
    final s = _roundPercent(strength);
    final o = _roundPercent(opacityLevel);
    if (s == 0.0 && (o - 1.0).abs() < .0001) {
      return FrostedGlassPerformanceMode.off;
    }
    if ((s - .35).abs() < .0001 && (o - .75).abs() < .0001) {
      return FrostedGlassPerformanceMode.highPerformance;
    }
    if ((s - 1.0).abs() < .0001 && o.abs() < .0001) {
      return FrostedGlassPerformanceMode.highQuality;
    }
    return FrostedGlassPerformanceMode.custom;
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
      _startThemeFileMaintenance();
    }
  }

  /// 将已初始化偏好应用到内存状态，供同步首帧与异步回退共用。
  void _applyStoredPreferences(AppPreferencesStore prefs) {
    _readThemePreferences(prefs);
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
            customGlassStrength >= 0 &&
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

    if (_modeForFrostedGlass(
            _frostedGlassCustomStrength, _customComponentOpacityLevel) !=
        FrostedGlassPerformanceMode.custom) {
      _frostedGlassCustomStrength = .65;
      _customComponentOpacityLevel = .65;
    }

    final glassMode = prefs.getString(_frostedGlassPerformanceModeKey);
    if (glassMode == null) {
      if (!_frostedGlass || _frostedGlassStrength == 0) {
        _frostedGlass = false;
        _frostedGlassPerformanceMode = FrostedGlassPerformanceMode.off;
      } else {
        _frostedGlassPerformanceMode =
            _modeForFrostedGlass(_frostedGlassStrength, componentOpacityLevel);
        if (_frostedGlassPerformanceMode == FrostedGlassPerformanceMode.custom) {
          if (customGlassStrength == null && _frostedGlassStrength > 0) {
            _frostedGlassCustomStrength = _frostedGlassStrength;
          }
          if (customOpacity == null) {
            _customComponentOpacityLevel = _roundPercent(componentOpacityLevel);
          }
        }
      }
    } else {
      _frostedGlassPerformanceMode =
          FrostedGlassPerformanceModeStorage.fromStorage(glassMode);
      if (_frostedGlassPerformanceMode != FrostedGlassPerformanceMode.off) {
        _frostedGlassPerformanceMode =
            _modeForFrostedGlass(_frostedGlassStrength, componentOpacityLevel);
        if (_frostedGlassPerformanceMode == FrostedGlassPerformanceMode.custom) {
          if (_frostedGlassStrength > 0 && customGlassStrength == null) {
            _frostedGlassCustomStrength = _frostedGlassStrength;
          }
          if (customOpacity == null) {
            _customComponentOpacityLevel = _roundPercent(componentOpacityLevel);
          }
        }
      }
    }
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

  Future<void> _setBackgroundMode(AppBackgroundMode mode) {
    _backgroundMode = mode;
    _appearance = _appearance.without(ThemeGroup.wallpapers);
    notifyListeners();
    return _queueAppearanceOperation((prefs) async {
        if (!await prefs.setString(
            _backgroundModeKey, _backgroundModeToString(mode))) {
          throw const FileSystemException('背景模式未能保存');
        }
        _backgroundMode = mode;
        await _clearWallpaperOverride(prefs);
      });
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

  Future<void> setBackgroundImage(String? imageUrl,
          {bool fillScreen = false}) =>
      _setManualWallpaper(imageUrl, fillScreen: fillScreen, landscape: false);

  Future<void> setLandscapeBackgroundImage(String? imageUrl,
          {bool fillScreen = false}) =>
      _setManualWallpaper(imageUrl, fillScreen: fillScreen, landscape: true);

  Future<void> _setManualWallpaper(String? image,
          {required bool fillScreen, required bool landscape}) =>
      _queueAppearanceOperation((prefs) async {
        var savedPath = image;
        if (image != null && isLocalFileBackground(image)) {
          final local = image.startsWith('file://')
              ? File.fromUri(Uri.parse(image)).path
              : image;
          if (await File(local).exists()) {
            await _initializeThemeFiles(prefs);
            savedPath = await themePacks.adoptWallpaper(local);
          }
        }
        final oldPath =
            landscape ? _landscapeBackgroundImage : _backgroundImage;
        final key =
            landscape ? _landscapeBackgroundImageKey : _backgroundImageKey;
        final fillKey = landscape
            ? _landscapeBackgroundFillScreenKey
            : _backgroundFillScreenKey;
        final hasValue = savedPath != null && savedPath.isNotEmpty;
        final results = hasValue
            ? [
                await prefs.setString(key, savedPath),
                await prefs.setBool(fillKey, fillScreen),
                await prefs.setString(_backgroundModeKey, 'custom'),
              ]
            : [await prefs.remove(key), await prefs.remove(fillKey)];
        if (!results.every((value) => value)) {
          throw const FileSystemException('壁纸偏好未能保存');
        }
        if (landscape) {
          _landscapeBackgroundImage = savedPath;
          _landscapeBackgroundFillScreen = hasValue && fillScreen;
        } else {
          _backgroundImage = savedPath;
          _backgroundFillScreen = hasValue && fillScreen;
        }
        if (hasValue) _backgroundMode = AppBackgroundMode.custom;
        await _clearWallpaperOverride(prefs);
        await _cleanupThemeFiles(legacyCandidates: [
          if (oldPath != null) oldPath,
          if (image != null) image
        ]);
      });

  Future<void> _clearWallpaperOverride(AppPreferencesStore prefs) async {
    if (_appearance.group(ThemeGroup.wallpapers) != null &&
        !await _writeCurrentAppearance(
            prefs, _appearance.without(ThemeGroup.wallpapers))) {
      throw const FileSystemException('主题壁纸偏好未能保存');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setBackgroundBlur(double blur) {
    final value = blur.clamp(0.0, 30.0);
    final brightness = effectiveBrightness;
    final tab = currentHomeTabIndex.value;
    _backgroundBlur = value;
    _appearance = _appearance.patchWallpaperBlur(brightness, tab, value);
    notifyListeners();
    return _queueAppearanceOperation((prefs) async {
      if (!await prefs.setDouble(_backgroundBlurKey, value)) {
        throw const FileSystemException('背景模糊未能保存');
      }
      if (_appearance.group(ThemeGroup.wallpapers) != null &&
          !await _writeCurrentAppearance(
              prefs, _appearance.patchWallpaperBlur(brightness, tab, value))) {
        throw const FileSystemException('主题背景模糊未能保存');
      }
    });
  }

  Future<bool> setComponentOpacityLevel(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    final level = (value.clamp(0.0, 1.0) * 100).round() / 100;
    return setComponentOpacity(
      minComponentOpacity + (1 - minComponentOpacity) * level,
    );
  }

  /// 保存底色偏好，界面滑块通过 [setComponentOpacityLevel] 换算后调用。
  Future<bool> setComponentOpacity(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    _useEffectiveMaterial();
    final opacity = value.clamp(0.0, 1.0);
    final brightness = effectiveBrightness;
    final oldMode = _frostedGlassPerformanceMode;
    final changed = _componentOpacity != opacity;
    _componentOpacity = opacity;
    _appearance =
        _appearance.patchMaterial(brightness, {'componentOpacity': opacity});
    _frostedGlassPerformanceMode = _modeForFrostedGlass(
      _frostedGlass ? _frostedGlassStrength : 0.0,
      componentOpacityLevel,
    );
    if (_frostedGlassPerformanceMode == FrostedGlassPerformanceMode.custom) {
      _customComponentOpacityLevel = _roundPercent(componentOpacityLevel);
      _frostedGlassCustomStrength = _frostedGlass ? _frostedGlassStrength : 0.0;
    }
    if (changed || oldMode != _frostedGlassPerformanceMode) notifyListeners();
    final customLevel = _customComponentOpacityLevel;
    final customStrength = _frostedGlassCustomStrength;
    final mode = _frostedGlassPerformanceMode.storageValue;
    return _queueCardAppearanceWrite((prefs) async {
      final results = [
        await prefs.setString(_frostedGlassPerformanceModeKey, mode),
        await prefs.setDouble(_componentOpacityKey, opacity),
        await prefs.setDouble(_customComponentOpacityLevelKey, customLevel),
        await prefs.setDouble(_frostedGlassCustomStrengthKey, customStrength),
      ];
      return results.every((saved) => saved) &&
          await _saveManualMaterial(
              prefs, brightness, {'componentOpacity': opacity});
    });
  }

  Future<void> setBottomNavStyle(BottomNavStyle style) async {
    _bottomNavStyle = BottomNavStyle.liquidGlass;
    _liquidGlass = true;
    _floatingNavBar = true;
    _appearance = _appearance.resetNavigationStyle();
    notifyListeners();
    await _queueAppearanceOperation((prefs) async {
      await _persistBottomNavPreferences(prefs);
      if (!await _saveManualNavigation(prefs)) {
        throw const FileSystemException('导航栏设置未能保存');
      }
    });
  }

  Future<bool> setBottomNavPerformanceMode(
    BottomNavPerformanceMode mode,
  ) {
    _useEffectiveNavigation();
    _bottomNavPerformanceMode = mode;
    _bottomNavAnimationIntensity = _motionPreset(mode);
    _appearance = _appearance.resetNavigationStyle();
    notifyListeners();
    return _persistBottomNavEffects();
  }

  Future<bool> setBottomNavAnimationIntensity(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    _useEffectiveNavigation();
    _bottomNavAnimationIntensity = (value.clamp(0.0, 1.0) * 100).round() / 100;
    if (_bottomNavPerformanceMode != BottomNavPerformanceMode.off ||
        _bottomNavAnimationIntensity > 0) {
      _bottomNavPerformanceMode = _modeForIntensity(_bottomNavAnimationIntensity);
      if (_bottomNavPerformanceMode == BottomNavPerformanceMode.custom) {
        _bottomNavCustomIntensity = _bottomNavAnimationIntensity;
      }
    }
    _appearance = _appearance.resetNavigationStyle();
    notifyListeners();
    return _persistBottomNavEffects();
  }

  /// 保存调用时的快照，连续拖动及预设切换按顺序落盘，失败可保存当前值重试。
  Future<bool> _persistBottomNavEffects() {
    final mode = _bottomNavPerformanceMode.storageValue;
    final intensity = _bottomNavAnimationIntensity;
    final custom = _bottomNavCustomIntensity;
    final clear = _bottomNavClearMaterial;
    return _queueCardAppearanceWrite((prefs) async {
      final results = [
        await prefs.setString(_bottomNavPerformanceModeKey, mode),
        await prefs.setDouble(_bottomNavAnimationIntensityKey, intensity),
        await prefs.setDouble('bottom_nav_custom_intensity', custom),
        await prefs.setBool('bottom_nav_clear_material', clear),
      ];
      return results.every((saved) => saved) &&
          await _saveManualNavigation(prefs);
    });
  }

  Future<void> setBottomNavClearMaterial(bool value) async {
    _useEffectiveNavigation();
    _bottomNavClearMaterial = value;
    _appearance = _appearance.resetNavigationStyle();
    notifyListeners();
    if (!await _persistBottomNavEffects()) throw const FileSystemException('导航栏材质未能保存');
  }

  void _useEffectiveNavigation() {
    _bottomNavAnimationIntensity = bottomNavAnimationIntensity;
    _bottomNavPerformanceMode = bottomNavPerformanceMode;
    _bottomNavClearMaterial = bottomNavClearMaterial;
  }

  Future<bool> _saveManualNavigation(AppPreferencesStore prefs) async {
    if (_appearance.group(ThemeGroup.navigation) == null) return true;
    return _writeCurrentAppearance(prefs, _appearance.resetNavigationStyle());
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
    _useEffectiveMaterial();
    final strength =
        value && _frostedGlassStrength == 0 ? 1.0 : _frostedGlassStrength;
    final oldMode = _frostedGlassPerformanceMode;
    final changed = _frostedGlass != value || _frostedGlassStrength != strength;
    _frostedGlass = value;
    _frostedGlassStrength = strength;
    _frostedGlassPerformanceMode = _modeForFrostedGlass(
      _frostedGlass ? _frostedGlassStrength : 0.0,
      componentOpacityLevel,
    );
    if (_frostedGlassPerformanceMode == FrostedGlassPerformanceMode.custom) {
      _frostedGlassCustomStrength = _frostedGlass ? _frostedGlassStrength : 0.0;
      _customComponentOpacityLevel = _roundPercent(componentOpacityLevel);
    }
    _previewMaterial(includeOpacity: false);
    if (changed || oldMode != _frostedGlassPerformanceMode) notifyListeners();
    return _persistFrostedGlass();
  }

  Future<bool> setFrostedGlassPerformanceMode(
      FrostedGlassPerformanceMode mode) {
    _useEffectiveMaterial();
    _frostedGlassPerformanceMode = mode;
    final (strength, opacityLevel) = _frostedGlassPreset(mode);
    final enabled = switch (mode) {
      FrostedGlassPerformanceMode.off => false,
      FrostedGlassPerformanceMode.highPerformance => true,
      FrostedGlassPerformanceMode.highQuality => true,
      FrostedGlassPerformanceMode.custom => strength > 0,
    };
    final opacity = minComponentOpacity +
        (1 - minComponentOpacity) * opacityLevel;
    _frostedGlass = enabled;
    _frostedGlassStrength = strength;
    _componentOpacity = opacity;
    _previewMaterial(includeOpacity: true);
    notifyListeners();
    return _persistFrostedGlass(includeOpacity: true);
  }

  /// 重试只保存当前数值，不能再次套用预设覆盖用户后续拖动。
  Future<bool> saveFrostedGlassSettings({bool includeOpacity = false}) =>
      _persistFrostedGlass(includeOpacity: includeOpacity);

  /// 拖动时立即预览，按顺序保存，避免较早的异步写入覆盖最终强度。
  /// 同值也允许保存，供存储失败后重试；设置页可从关闭状态向上拖动启用模糊。
  Future<bool> setFrostedGlassStrength(double value) {
    if (!value.isFinite) return Future<bool>.value(false);
    _useEffectiveMaterial();
    final strength = (value.clamp(0.0, 1.0) * 100).round() / 100;
    final enabled = strength > 0;
    final oldMode = _frostedGlassPerformanceMode;
    final changed = _frostedGlassStrength != strength || _frostedGlass != enabled;
    _frostedGlassStrength = strength;
    _frostedGlass = enabled;
    _frostedGlassPerformanceMode = _modeForFrostedGlass(
      _frostedGlass ? _frostedGlassStrength : 0.0,
      componentOpacityLevel,
    );
    if (_frostedGlassPerformanceMode == FrostedGlassPerformanceMode.custom) {
      _frostedGlassCustomStrength = _frostedGlass ? _frostedGlassStrength : 0.0;
      _customComponentOpacityLevel = _roundPercent(componentOpacityLevel);
    }
    _previewMaterial(includeOpacity: false);
    if (changed || oldMode != _frostedGlassPerformanceMode) notifyListeners();
    return _persistFrostedGlass();
  }

  Future<bool> _persistFrostedGlass(
      {bool includeEnabled = true, bool includeOpacity = false}) {
    final brightness = effectiveBrightness;
    final mode = _frostedGlassPerformanceMode.storageValue;
    final enabled = _frostedGlass;
    final strength = _frostedGlassStrength;
    final customStrength = _frostedGlassCustomStrength;
    final customOpacityLevel = _customComponentOpacityLevel;
    final opacity = _componentOpacity;
    return _queueCardAppearanceWrite((prefs) async {
      final results = [
        await prefs.setString(_frostedGlassPerformanceModeKey, mode),
        await prefs.setDouble(_frostedGlassStrengthKey, strength),
        await prefs.setDouble(_frostedGlassCustomStrengthKey, customStrength),
        await prefs.setDouble(_customComponentOpacityLevelKey, customOpacityLevel),
        if (includeEnabled) await prefs.setBool(_frostedGlassKey, enabled),
        if (includeOpacity) await prefs.setDouble(_componentOpacityKey, opacity),
      ];
      return results.every((saved) => saved) &&
          await _saveManualMaterial(prefs, brightness, {
            'frostedGlass': {'enabled': enabled, 'strength': strength},
            if (includeOpacity) 'componentOpacity': opacity,
          });
    });
  }

  Future<bool> _queueCardAppearanceWrite(
      Future<bool> Function(AppPreferencesStore) save) {
    return _queueAppearanceOperation(save).catchError((_) => false);
  }

  Future<T> _queueAppearanceOperation<T>(
      Future<T> Function(AppPreferencesStore) action) {
    final operation =
        (_cardAppearanceWrites ?? Future<void>.value()).then((_) async {
      final prefs = await AppPreferencesStore.getInstance();
      _readThemePreferences(prefs);
      return action(prefs);
    });
    _cardAppearanceWrites =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  void _useEffectiveMaterial() {
    if (_activeMaterial == null) return;
    _componentOpacity = componentOpacity;
    _frostedGlass = _activeMaterial!['frostedGlass']['enabled'] as bool;
    _frostedGlassStrength = frostedGlassStrength;
  }

  void _previewMaterial({required bool includeOpacity}) {
    _appearance = _appearance.patchMaterial(effectiveBrightness, {
      'frostedGlass': {
        'enabled': _frostedGlass,
        'strength': _frostedGlassStrength
      },
      if (includeOpacity) 'componentOpacity': _componentOpacity,
    });
  }

  Future<bool> _saveManualMaterial(AppPreferencesStore prefs, Brightness mode,
      Map<String, dynamic> patch) async {
    if (_appearance.group(ThemeGroup.material) == null) return true;
    return _writeCurrentAppearance(
        prefs, _appearance.patchMaterial(mode, patch));
  }

  ThemeAppearance get appearance => _trial?.appearance ?? _appearance;
  ThemeAppearance get persistedAppearance => _appearance;
  ThemeTrialSession? get trial => _trial;
  bool get isInTrial => _trial != null;
  bool get hasPreviousAppearance => _previousAppearance != null;
  bool get canApplyBetaDefault =>
      _isLoaded &&
      _trial == null &&
      AppPreferencesStore.maybeInstance?.containsKey(appearanceKey) == false;
  bool get hasThemeColors => appearance.group(ThemeGroup.colors) != null;
  String? get themeStorageWarning => _themeStorageWarning;
  String get currentAppearanceSummary {
    if (_trial != null) {
      return '试用中：${_trial!.manifest.name} · v${_trial!.manifest.version}';
    }
    final manualSummary = shouldShowCustomBackground ? '自定义背景外观' : '默认外观';
    return _appearance.summaryLabel(manualSummary: manualSummary);
  }

  String get suggestedExportName =>
      _appearance.singleThemeName ??
      ( _appearance.activeGroupSources.isNotEmpty ? '我的混搭外观' : '当前外观');

  Brightness get effectiveBrightness => _followSystem
      ? WidgetsBinding.instance.platformDispatcher.platformBrightness
      : _isDarkMode
          ? Brightness.dark
          : Brightness.light;
  String get _appearanceMode =>
      effectiveBrightness == Brightness.dark ? 'dark' : 'light';
  Map<String, dynamic>? get _materialGroup =>
      appearance.group(ThemeGroup.material);
  Map<String, dynamic>? get _activeMaterial =>
      _materialGroup?[_appearanceMode] as Map<String, dynamic>?;
  Map<String, dynamic>? get _wallpaperGroup =>
      appearance.group(ThemeGroup.wallpapers);
  Map<String, dynamic>? get _legacyWallpaper =>
      _wallpaperGroup?['legacy'] as Map<String, dynamic>?;
  Map<String, dynamic>? get _navigationGroup =>
      appearance.group(ThemeGroup.navigation);
  Map<String, dynamic>? get _navigationMotion =>
      _navigationGroup?['motion'] as Map<String, dynamic>?;
  bool get usesThemeWallpapers =>
      _wallpaperGroup != null && _legacyWallpaper == null;
  bool get canCustomizeCardMaterial =>
      shouldShowCustomBackground || (_materialGroup != null && _materialGroup!['legacy'] != true);

  Map<String, dynamic>? get themeWallpaper {
    return themeWallpaperFor();
  }

  Map<String, dynamic>? themeWallpaperFor({bool secondary = false}) {
    if (!usesThemeWallpapers) return null;
    final slots = _wallpaperGroup![_appearanceMode] as Map;
    // 二级页面优先用 secondary 槽位，主壳页签按页签取槽位；都没有时回退到 global。
    final slot = secondary
        ? 'secondary'
        : switch (currentHomeTabIndex.value) {
            0 => 'home',
            2 => 'schedule',
            4 => 'me',
            _ => 'global'
          };
    return (slots[slot] ?? slots['global']) as Map<String, dynamic>?;
  }

  ThemeData buildAppTheme(Brightness brightness) =>
      appearance.buildTheme(brightness);

  void _readThemePreferences(AppPreferencesStore prefs) {
    if (_appearanceLoaded) return;
    final current = prefs.getString(appearanceKey);
    final previous = prefs.getString(previousAppearanceKey);
    _appearance = current == null
        ? const ThemeAppearance.empty()
        : ThemeAppearance(jsonDecode(current) as Map<String, dynamic>);
    _previousAppearance = previous == null
        ? null
        : ThemeAppearance(jsonDecode(previous) as Map<String, dynamic>);
    _appearanceLoaded = true;
    final fontGroup = _appearance.group(ThemeGroup.font);
    if (fontGroup != null &&
        ThemeFontRegistry.resolvedFamilyFor(fontGroup) == null) {
      unawaited(
        ThemeFontRegistry.ensureLoaded(fontGroup).then((loaded) {
          if (loaded != null && !_disposed) notifyListeners();
        }),
      );
    }
    unawaited(
      HomeWidgetService.syncThemeAppearance(_appearance, prefs: prefs)
          .catchError((Object _) {}),
    );
  }

  void _onThemeTabChanged() {
    if (!usesThemeWallpapers) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (_followSystem &&
        (_materialGroup != null ||
            usesThemeWallpapers ||
            appearance.group(ThemeGroup.decoration) != null)) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    currentHomeTabIndex.removeListener(_onThemeTabChanged);
    super.dispose();
  }

  ThemeAppearance _snapshotAppearance([AppPreferencesStore? prefs]) {
    final persistedWallpapers = _appearance.group(ThemeGroup.wallpapers);
    final persistedMaterial = _appearance.group(ThemeGroup.material);
    final persistedNav = _appearance.group(ThemeGroup.navigation);
    final persistedWidgets = _appearance.group(ThemeGroup.widgets);
    final persistedMotion = persistedNav?['motion'] as Map<String, dynamic>?;
    final persistedNavStyle = persistedNav?['style'] != null
        ? persistedNav!['style'] as String
        : (_bottomNavPerformanceMode == BottomNavPerformanceMode.off
                ? BottomNavStyle.floating
                : _bottomNavStyle)
            .storageValue;
    return ThemeAppearance({
      ..._appearance.data,
      if (persistedWallpapers == null)
        'wallpapers': {
          'source': null,
          'legacy': {
            'mode': _backgroundMode.name,
            'portrait': _backgroundImage,
            'landscape': _landscapeBackgroundImage,
            'portraitFill': _backgroundFillScreen,
            'landscapeFill': _landscapeBackgroundFillScreen,
            'blur': _backgroundBlur,
          }
        },
      if (persistedMaterial == null)
        'material': {
          'source': null,
          'legacy': true,
          for (final mode in ['light', 'dark'])
            mode: {
              'componentOpacity': _componentOpacity,
              'frostedGlass': {
                'enabled': _frostedGlass,
                'strength': _frostedGlassStrength
              },
            }
        },
      if (persistedWidgets == null && prefs != null)
        'widgets': {
          'source': null,
          'legacy': {
            'courseTheme':
                prefs.getString(HomeWidgetPreferenceKeys.courseTheme) ??
                    HomeWidgetTheme.system.storageName,
            'examTheme':
                prefs.getString(HomeWidgetPreferenceKeys.examTheme) ??
                    HomeWidgetTheme.system.storageName,
          },
        },
      'navigation': {
        'source': null,
        ...?persistedNav,
        'style': persistedNavStyle,
        'icons': persistedNav?['icons'] ?? <String, dynamic>{},
        'iconTint': persistedNav?['iconTint'] ?? 'template',
        'motion': {
          'intensity': (persistedMotion?['intensity'] as num?)?.toDouble() ??
              _bottomNavAnimationIntensity,
          'performanceMode':
              (persistedMotion?['performanceMode'] as String?) ??
                  _bottomNavPerformanceMode.storageValue,
          'clearMaterial': (persistedMotion?['clearMaterial'] as bool?) ??
              _bottomNavClearMaterial,
        },
      },
    });
  }

  /// 开启全局试用会话：仅在内存与临时暂存目录生效，不写任何偏好存储，进程退出自然恢复。
  Future<void> startTrial({
    InstalledTheme? installed,
    PreparedThemePack? pack,
    required Set<ThemeGroup> groups,
  }) async {
    assert(installed != null || pack != null);
    final manifest = installed?.manifest ?? pack!.manifest;
    final selected = Set<ThemeGroup>.of(groups)
        .intersection(ThemeGroup.applicable)
        .intersection(manifest.groups);
    if (selected.isEmpty) return;
    final generation = ++_trialGeneration;
    final previousStaging = _trial?.stagingDirectory;
    String? stagingDirectory;
    String directory;
    if (installed != null) {
      directory = installed.directory;
    } else {
      stagingDirectory = await themePacks.stageTrial(pack!);
      if (_disposed || generation != _trialGeneration) {
        await themePacks.removeStagingDirectory(stagingDirectory);
        return;
      }
      directory = stagingDirectory;
    }
    final trialAppearance = _appearance.apply(manifest, selected, directory);
    await ThemeFontRegistry.ensureLoaded(
      trialAppearance.group(ThemeGroup.font),
      inMemoryContents: pack?.contents,
    );
    if (_disposed || generation != _trialGeneration) {
      if (stagingDirectory != null) {
        await themePacks.removeStagingDirectory(stagingDirectory);
      }
      return;
    }
    _trial = ThemeTrialSession(
      manifest: manifest,
      groups: selected,
      appearance: trialAppearance,
      installed: installed,
      pack: pack,
      stagingDirectory: stagingDirectory,
    );
    if (!_disposed) notifyListeners();
    if (previousStaging != null && previousStaging != stagingDirectory) {
      await themePacks.removeStagingDirectory(previousStaging);
    }
  }

  Future<void> endTrial() async {
    _trialGeneration++;
    final previous = _trial;
    if (previous == null) return;
    _trial = null;
    if (!_disposed) notifyListeners();
    if (previous.stagingDirectory != null) {
      await themePacks.removeStagingDirectory(previous.stagingDirectory);
    }
  }

  Future<void> _recordManualWidgetThemesBeforeThemeApply(
    AppPreferencesStore prefs,
  ) async {
    if (_appearance.group(ThemeGroup.widgets) != null) return;
    if (!prefs.containsKey(HomeWidgetPreferenceKeys.manualCourseTheme)) {
      await prefs.setString(
        HomeWidgetPreferenceKeys.manualCourseTheme,
        prefs.getString(HomeWidgetPreferenceKeys.courseTheme) ??
            HomeWidgetTheme.system.storageName,
      );
    }
    if (!prefs.containsKey(HomeWidgetPreferenceKeys.manualExamTheme)) {
      await prefs.setString(
        HomeWidgetPreferenceKeys.manualExamTheme,
        prefs.getString(HomeWidgetPreferenceKeys.examTheme) ??
            HomeWidgetTheme.system.storageName,
      );
    }
  }

  Future<void> _applySystemCapabilities({
    required AppPreferencesStore prefs,
    required ThemeAppearance next,
    required Set<ThemeGroup> selected,
    required ThemeManifest manifest,
  }) async {
    final applyWidgets = selected.contains(ThemeGroup.widgets);
    await HomeWidgetService.syncThemeAppearance(
      next,
      prefs: prefs,
      courseThemeOverride:
          applyWidgets ? HomeWidgetTheme.appTheme.storageName : null,
      examThemeOverride:
          applyWidgets ? HomeWidgetTheme.appTheme.storageName : null,
    );
    if (selected.contains(ThemeGroup.launcherIcon)) {
      final builtinId = manifest.data['launcherIcon']?['builtin'] as String?;
      if (builtinId != null && builtinId.isNotEmpty) {
        final themed = await LauncherIconService.readDesiredThemed(prefs);
        await LauncherIconService.setDesired(
          prefs: prefs,
          id: builtinId,
          themed: themed,
        );
      }
    }
  }

  Future<void> applyTrial() {
    final active = _trial;
    if (active == null) return Future<void>.value();
    _trialGeneration++;
    return _queueAppearanceOperation((prefs) async {
      if (!_isLoaded) {
        _applyStoredPreferences(prefs);
        _isLoaded = true;
      }
      await _initializeThemeFiles(prefs);
      InstalledTheme target;
      if (active.installed != null) {
        target = active.installed!;
      } else {
        final existing = await themePacks.findInstalledVersion(
          active.manifest.id,
          active.manifest.version,
        );
        target = existing ?? await themePacks.install(active.pack!);
      }
      final snapshot = _snapshotAppearance(prefs);
      final next =
          _appearance.apply(target.manifest, active.groups, target.directory);
      await ThemeFontRegistry.ensureLoaded(next.group(ThemeGroup.font));
      if (active.groups.contains(ThemeGroup.widgets)) {
        await _recordManualWidgetThemesBeforeThemeApply(prefs);
      }
      await _commitAppearance(prefs, next, snapshot, notifyImmediately: false);
      _trial = null;
      if (!_disposed) notifyListeners();
      await _applySystemCapabilities(
        prefs: prefs,
        next: next,
        selected: active.groups,
        manifest: target.manifest,
      );
      if (active.stagingDirectory != null) {
        await themePacks.removeStagingDirectory(active.stagingDirectory);
      }
      await _cleanupThemeFiles();
    });
  }

  Future<Uint8List> exportCurrentAppearance({
    String? customName,
    String? authorName,
    String? appVersion,
  }) async {
    final effective = _appearance;
    final hasThemeWalls = effective.group(ThemeGroup.wallpapers) != null &&
        effective.group(ThemeGroup.wallpapers)!['legacy'] == null;
    RawWallpaperInput? manualPortrait;
    RawWallpaperInput? manualLandscape;
    if (!hasThemeWalls && _backgroundMode == AppBackgroundMode.custom) {
      manualPortrait = await ThemeAppearanceExporter.readWallpaperSource(
        _backgroundImage,
        fillScreen: _backgroundFillScreen,
        blur: _backgroundBlur,
        isBundledAsset: isBundledAssetBackground,
        isLocalFile: isLocalFileBackground,
        resolveBundledAssetPath: resolveBundledAssetPath,
      );
      manualLandscape = await ThemeAppearanceExporter.readWallpaperSource(
        _landscapeBackgroundImage,
        fillScreen: _landscapeBackgroundFillScreen,
        blur: _backgroundBlur,
        isBundledAsset: isBundledAssetBackground,
        isLocalFile: isLocalFileBackground,
        resolveBundledAssetPath: resolveBundledAssetPath,
      );
    }
    final persistedMat = effective.group(ThemeGroup.material);
    final hasExplicitMaterial =
        persistedMat != null && persistedMat['legacy'] != true;
    final shouldExportManualMat = !hasExplicitMaterial &&
        (manualPortrait != null ||
            manualLandscape != null ||
            _frostedGlass ||
            _componentOpacity < 1.0);
    final persistedNavStyle =
        (_bottomNavPerformanceMode == BottomNavPerformanceMode.off
                ? BottomNavStyle.floating
                : _bottomNavStyle)
            .storageValue;
    return ThemeAppearanceExporter.export(
      appearance: effective,
      name: customName ?? suggestedExportName,
      author: authorName ?? '本机导出',
      appVersion: appVersion ?? '1.0.0',
      bottomNavStyle: persistedNavStyle,
      shouldExportManualMaterial: shouldExportManualMat,
      manualComponentOpacity: _componentOpacity,
      manualFrostedGlass: _frostedGlass,
      manualFrostedStrength: _frostedGlassStrength,
      manualPortraitWallpaper: manualPortrait,
      manualLandscapeWallpaper: manualLandscape,
    );
  }

  Future<List<InstalledTheme>> installedThemes() =>
      _queueAppearanceOperation((prefs) async {
        await _initializeThemeFiles(prefs);
        return themePacks.list();
      });

  Future<InstalledTheme> installTheme(
    PreparedThemePack pack, {
    bool reuseExisting = false,
  }) =>
      _queueAppearanceOperation((prefs) async {
        await _initializeThemeFiles(prefs);
        if (reuseExisting) {
          final existing = await themePacks.findInstalledVersion(
            pack.manifest.id,
            pack.manifest.version,
          );
          if (existing != null) return existing;
        }
        return themePacks.install(pack);
      });

  Future<InstalledTheme> installStoreTheme(
    PreparedThemePack pack, {
    required String source,
    required String familyId,
  }) =>
      _queueAppearanceOperation((prefs) async {
        await _initializeThemeFiles(prefs);
        final existing = await themePacks.findInstalledVersion(
          pack.manifest.id,
          pack.manifest.version,
        );
        if (existing != null) {
          return InstalledTheme(
            existing.manifest,
            existing.directory,
            existing.installedAt,
            source: source,
            familyId: familyId,
          );
        }
        return themePacks.install(pack, source: source, familyId: familyId);
      });

  /// 判断指定主题版本是否为当前已持久化的主要生效外观（配色分组来源）。
  bool isThemeVersionActive(String themeId, int version) {
    final src = _appearance.group(ThemeGroup.colors)?['source'] as Map?;
    if (src == null) return false;
    final activeId = (src['themeId'] ?? src['id'])?.toString().toLowerCase();
    return activeId == themeId.toLowerCase() && src['version'] == version;
  }

  Future<bool> applyInstalledTheme(
    InstalledTheme theme,
    Set<ThemeGroup> groups, {
    bool resetMissingGroups = false,
    bool asBetaDefault = false,
  }) {
    final selected = Set<ThemeGroup>.of(groups)
        .intersection(ThemeGroup.applicable)
        .intersection(theme.manifest.groups);
    return _queueAppearanceOperation((prefs) async {
      if (!_isLoaded) {
        _applyStoredPreferences(prefs);
        _isLoaded = true;
      }
      await _initializeThemeFiles(prefs);
      if (asBetaDefault &&
          (_trial != null || prefs.containsKey(appearanceKey))) {
        return false;
      }
      final oldTrialStaging = _trial?.stagingDirectory;
      _trialGeneration++;
      _trial = null;
      final snapshot = _snapshotAppearance(prefs);
      var next = _appearance.apply(theme.manifest, selected, theme.directory);
      if (resetMissingGroups) {
        // 本机编辑时，移除草稿里的最后一个资源也属于一次修改。
        for (final group in groups.difference(selected)) {
          next = next.without(group);
        }
      }
      await ThemeFontRegistry.ensureLoaded(next.group(ThemeGroup.font));
      if (selected.contains(ThemeGroup.widgets)) {
        await _recordManualWidgetThemesBeforeThemeApply(prefs);
      }
      await _commitAppearance(prefs, next, snapshot);
      await _applySystemCapabilities(
        prefs: prefs,
        next: next,
        selected: selected,
        manifest: theme.manifest,
      );
      if (oldTrialStaging != null) {
        await themePacks.removeStagingDirectory(oldTrialStaging);
      }
      await _cleanupThemeFiles();
      return true;
    });
  }

  Future<void> restorePreviousAppearance() =>
      _queueAppearanceOperation((prefs) async {
        final previous = _previousAppearance;
        if (previous == null) return;
        final oldTrialStaging = _trial?.stagingDirectory;
        _trialGeneration++;
        _trial = null;
        final snapshot = _snapshotAppearance(prefs);
        await ThemeFontRegistry.ensureLoaded(previous.group(ThemeGroup.font));
        await _commitAppearance(prefs, previous, snapshot);
        final previousWidgets = previous.group(ThemeGroup.widgets);
        String? courseOverride;
        String? examOverride;
        if (previousWidgets != null) {
          final legacy = previousWidgets['legacy'] as Map?;
          if (legacy != null) {
            courseOverride = legacy['courseTheme'] as String?;
            examOverride = legacy['examTheme'] as String?;
          } else {
            courseOverride = HomeWidgetTheme.appTheme.storageName;
            examOverride = HomeWidgetTheme.appTheme.storageName;
          }
        }
        await HomeWidgetService.syncThemeAppearance(
          previous,
          prefs: prefs,
          courseThemeOverride: courseOverride,
          examThemeOverride: examOverride,
        );
        if (oldTrialStaging != null) {
          await themePacks.removeStagingDirectory(oldTrialStaging);
        }
        await _cleanupThemeFiles();
      });

  Future<void> restoreManualAppearance() =>
      _queueAppearanceOperation((prefs) async {
        final oldTrialStaging = _trial?.stagingDirectory;
        final hadThemeWidgets = _appearance.group(ThemeGroup.widgets) != null;
        _trialGeneration++;
        _trial = null;
        const cleared = ThemeAppearance.empty();
        await _commitAppearance(prefs, cleared, _snapshotAppearance(prefs));
        String? courseOverride;
        String? examOverride;
        if (hadThemeWidgets) {
          courseOverride =
              prefs.getString(HomeWidgetPreferenceKeys.manualCourseTheme) ??
                  HomeWidgetTheme.system.storageName;
          examOverride =
              prefs.getString(HomeWidgetPreferenceKeys.manualExamTheme) ??
                  HomeWidgetTheme.system.storageName;
        }
        await HomeWidgetService.syncThemeAppearance(
          cleared,
          prefs: prefs,
          courseThemeOverride: courseOverride,
          examThemeOverride: examOverride,
        );
        // 恢复手动外观不改动已生效的桌面图标，避免退出主题时触发桌面重载。
        if (oldTrialStaging != null) {
          await themePacks.removeStagingDirectory(oldTrialStaging);
        }
        await _cleanupThemeFiles();
      });

  Future<void> deleteInstalledTheme(String id) =>
      _queueAppearanceOperation((prefs) async {
        await themePacks.remove(id);
        await _cleanupThemeFiles();
        if (!_disposed) notifyListeners();
      });

  Future<void> retryThemeFileCleanup() =>
      _queueAppearanceOperation((prefs) async {
        await _initializeThemeFiles(prefs);
        await _cleanupThemeFiles();
      });

  Future<void> updateCardStyle(
    Brightness brightness,
    Map<String, dynamic>? cardStyle,
  ) =>
      _queueAppearanceOperation((prefs) async {
        if (!_isLoaded) {
          _applyStoredPreferences(prefs);
          _isLoaded = true;
        }
        final next = _appearance.patchCardStyle(
          brightness,
          cardStyle,
          fallbackOpacity: _componentOpacity,
          fallbackFrosted: _frostedGlass,
          fallbackStrength: _frostedGlassStrength,
        );
        if (!await _writeCurrentAppearance(prefs, next)) {
          throw const FileSystemException('卡片样式未能保存');
        }
      });

  Future<void> updateHeaderLayout(
    String slot,
    Map<String, dynamic>? headerLayout,
  ) =>
      _queueAppearanceOperation((prefs) async {
        if (!_isLoaded) {
          _applyStoredPreferences(prefs);
          _isLoaded = true;
        }
        final next = _appearance.patchHeaderLayout(slot, headerLayout);
        if (!await _writeCurrentAppearance(prefs, next)) {
          throw const FileSystemException('页头布局未能保存');
        }
      });

  Future<String> adoptDecorationImage(
    String sourcePath,
    ThemeAssetKind kind,
  ) =>
      _queueAppearanceOperation((prefs) async {
        await _initializeThemeFiles(prefs);
        final local = sourcePath.startsWith('file://')
            ? File.fromUri(Uri.parse(sourcePath)).path
            : sourcePath;
        await ThemePackCodec.validateLocalImageFile(local, kind);
        return themePacks.adoptWallpaper(local);
      });

  Future<void> updateHeaderDecoration(
    Brightness brightness,
    String slot,
    Map<String, dynamic>? slotDecoration,
  ) =>
      _queueAppearanceOperation((prefs) async {
        if (!_isLoaded) {
          _applyStoredPreferences(prefs);
          _isLoaded = true;
        }
        await _initializeThemeFiles(prefs);
        final next =
            _appearance.patchHeaderDecoration(brightness, slot, slotDecoration);
        if (!await _writeCurrentAppearance(prefs, next)) {
          throw const FileSystemException('页头装饰未能保存');
        }
        await _cleanupThemeFiles();
      });

  Future<void> resetAppearanceGroup(ThemeGroup group) =>
      _queueAppearanceOperation((prefs) async {
        if (!_isLoaded) {
          _applyStoredPreferences(prefs);
          _isLoaded = true;
        }
        await _initializeThemeFiles(prefs);
        final next = _appearance.without(group);
        if (!await _writeCurrentAppearance(prefs, next)) {
          throw const FileSystemException('外观分组未能重置');
        }
        await _cleanupThemeFiles();
      });

  Future<void> _commitAppearance(
    AppPreferencesStore prefs,
    ThemeAppearance next,
    ThemeAppearance previous, {
    bool notifyImmediately = true,
  }) async {
    final oldPrevious = prefs.getString(previousAppearanceKey);
    if (!await prefs.setString(
        previousAppearanceKey, jsonEncode(previous.data))) {
      throw const FileSystemException('上一个外观未能保存');
    }
    var committed = false;
    try {
      committed = await prefs.setString(appearanceKey, jsonEncode(next.data));
    } finally {
      if (!committed) {
        if (oldPrevious == null) {
          await prefs.remove(previousAppearanceKey);
        } else {
          await prefs.setString(previousAppearanceKey, oldPrevious);
        }
      }
    }
    if (!committed) throw const FileSystemException('当前外观未能保存');
    _appearance = next;
    _previousAppearance = previous;
    if (notifyImmediately && !_disposed) notifyListeners();
  }

  Future<bool> _writeCurrentAppearance(
      AppPreferencesStore prefs, ThemeAppearance next) async {
    if (!await prefs.setString(appearanceKey, jsonEncode(next.data))) {
      return false;
    }
    _appearance = next;
    if (!_disposed) notifyListeners();
    return true;
  }

  Iterable<String> get _protectedThemePaths => [
        ..._appearance.paths,
        ...?_previousAppearance?.paths,
        ...?_trial?.appearance.paths,
        if (_backgroundImage != null) _backgroundImage!,
        if (_landscapeBackgroundImage != null) _landscapeBackgroundImage!,
      ];

  Future<void> _cleanupThemeFiles(
      {List<String> legacyCandidates = const []}) async {
    if (!_themeFilesInitialized) return;
    try {
      await themePacks.cleanup(
          retainedPaths: _protectedThemePaths,
          retainedVersions: [
            ..._appearance.versions,
            ...?_previousAppearance?.versions,
            ...?_trial?.appearance.versions,
          ]);
      final retained = _protectedThemePaths.map(path.normalize).toSet();
      for (final old in legacyCandidates) {
        if (isLocalFileBackground(old) &&
            !retained.contains(path.normalize(old))) {
          await themePacks.removeLegacyWallpaper(old);
        }
      }
      _themeStorageWarning = null;
    } on FileSystemException {
      _themeStorageWarning = '外观已保存，部分旧主题文件未能清理';
    }
    if (!_disposed) notifyListeners();
  }

  void _startThemeFileMaintenance() {
    if (_appearance.data.isEmpty &&
        ![_backgroundImage, _landscapeBackgroundImage].any((image) => image != null && isLocalFileBackground(image))) {
      return;
    }
    unawaited(_queueAppearanceOperation((prefs) => _initializeThemeFiles(prefs))
        .catchError((Object error) {
      if (_appearance.data.isNotEmpty) {
        _themeStorageWarning = '本机主题文件整理未完成，请在主题设置中重试';
        if (!_disposed) notifyListeners();
      }
    }));
  }

  Future<void> _initializeThemeFiles(AppPreferencesStore prefs) async {
    if (_themeFilesInitialized) return;
    await themePacks.clearStaging(
      keepIncomingPath: ThemeIncomingCoordinator.instance.current?.filePath,
    );
    for (final pair in [
      (_backgroundImageKey, _backgroundImage),
      (_landscapeBackgroundImageKey, _landscapeBackgroundImage)
    ]) {
      final old = pair.$2;
      if (old == null || !isLocalFileBackground(old)) continue;
      final source =
          old.startsWith('file://') ? File.fromUri(Uri.parse(old)).path : old;
      final adopted = await themePacks.adoptWallpaper(source);
      if (adopted == source) continue;
      if (!await prefs.setString(pair.$1, adopted)) {
        throw const FileSystemException('壁纸路径未能保存');
      }
      if (pair.$1 == _backgroundImageKey) {
        _backgroundImage = adopted;
      } else {
        _landscapeBackgroundImage = adopted;
      }
      _appearance = _appearance.replacePath(old, adopted);
      _previousAppearance = _previousAppearance?.replacePath(old, adopted);
      if (_appearance.data.isNotEmpty &&
          !await prefs.setString(appearanceKey, jsonEncode(_appearance.data))) {
        throw const FileSystemException('迁移后的当前外观未能保存');
      }
      if (_previousAppearance != null &&
          !await prefs.setString(
              previousAppearanceKey, jsonEncode(_previousAppearance!.data))) {
        throw const FileSystemException('迁移后的上一个外观未能保存');
      }
      await themePacks.removeLegacyWallpaper(source);
    }
    _themeFilesInitialized = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> clearBackground() => _queueAppearanceOperation((prefs) async {
        final old = [
          if (_backgroundImage != null) _backgroundImage!,
          if (_landscapeBackgroundImage != null) _landscapeBackgroundImage!
        ];
        final results = [
          await prefs.remove(_backgroundImageKey),
          await prefs.remove(_landscapeBackgroundImageKey),
          await prefs.remove(_backgroundFillScreenKey),
          await prefs.remove(_landscapeBackgroundFillScreenKey),
          await prefs.setString(_backgroundModeKey, 'clean'),
        ];
        if (!results.every((value) => value)) {
          throw const FileSystemException('背景偏好未能保存');
        }
        _backgroundImage = null;
        _landscapeBackgroundImage = null;
        _backgroundFillScreen = false;
        _landscapeBackgroundFillScreen = false;
        _backgroundMode = AppBackgroundMode.clean;
        await _clearWallpaperOverride(prefs);
        await _cleanupThemeFiles(legacyCandidates: old);
      });

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
