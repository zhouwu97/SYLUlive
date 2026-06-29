import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _nightModeKey = 'night_mode';
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
  static const String _predictiveBackKey = 'predictive_back_enabled';
  static const String _startOnTimetableKey = 'start_on_timetable';
  static const String _marketIsListViewKey = 'market_is_list_view';

  bool _isDarkMode = false;
  String? _backgroundImage;
  String? _landscapeBackgroundImage;
  bool _backgroundFillScreen = false;
  bool _landscapeBackgroundFillScreen = false;
  double _backgroundBlur = 10;
  double _componentOpacity = 0.7; // 组件不透明度：越大越实，越小越透
  bool _liquidGlass = false;
  bool _floatingNavBar = false;
  bool _predictiveBack = true;
  bool _startOnTimetable = false;
  bool _marketIsListView = false;

  bool get isDarkMode => _isDarkMode;
  String? get backgroundImage => _backgroundImage;
  String? get landscapeBackgroundImage => _landscapeBackgroundImage;
  bool get backgroundFillScreen => _backgroundFillScreen;
  bool get landscapeBackgroundFillScreen => _landscapeBackgroundFillScreen;
  double get backgroundBlur => _backgroundBlur;
  double get componentOpacity => _componentOpacity;
  bool get liquidGlass => _liquidGlass;
  bool get floatingNavBar => _floatingNavBar;
  bool get predictiveBack => _predictiveBack;
  bool get startOnTimetable => _startOnTimetable;
  bool get marketIsListView => _marketIsListView;
  bool get hasBackground =>
      _backgroundImage != null && _backgroundImage!.isNotEmpty;
  bool get hasLandscapeBackground =>
      _landscapeBackgroundImage != null &&
      _landscapeBackgroundImage!.isNotEmpty;

  /// 是否有自定义背景（全局生效）
  bool get isBackgroundVisible => hasBackground || hasLandscapeBackground;

  static bool isNetworkBackground(String imagePath) {
    return imagePath.startsWith('http://') || imagePath.startsWith('https://');
  }

  static bool isLocalFileBackground(String imagePath) {
    return imagePath.startsWith('/') ||
        imagePath.startsWith(r'\\') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(imagePath);
  }

  static bool isBundledAssetBackground(String imagePath) {
    return !isNetworkBackground(imagePath) && !isLocalFileBackground(imagePath);
  }

  static String resolveBundledAssetPath(String imagePath) {
    return imagePath.startsWith('assets/')
        ? imagePath
        : 'assets/images/$imagePath';
  }

  /// 获取当前环境适用的背景图片
  String? getBackgroundImageFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide && hasLandscapeBackground) {
      return _landscapeBackgroundImage;
    }
    return _backgroundImage;
  }

  bool getBackgroundFillScreenFor(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    if (isWide && hasLandscapeBackground) {
      return _landscapeBackgroundFillScreen;
    }
    return _backgroundFillScreen;
  }

  ThemeProvider() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_nightModeKey) ?? false;
    _backgroundImage = prefs.getString(_backgroundImageKey);
    _landscapeBackgroundImage = prefs.getString(_landscapeBackgroundImageKey);
    _backgroundFillScreen = prefs.getBool(_backgroundFillScreenKey) ?? false;
    _landscapeBackgroundFillScreen =
        prefs.getBool(_landscapeBackgroundFillScreenKey) ?? false;
    _backgroundBlur = prefs.getDouble(_backgroundBlurKey) ?? 10;
    _componentOpacity = prefs.getDouble(_componentOpacityKey) ?? 0.7;
    _liquidGlass = prefs.getBool(_liquidGlassKey) ?? false;
    _floatingNavBar = prefs.getBool(_floatingNavBarKey) ?? false;
    _predictiveBack = prefs.getBool(_predictiveBackKey) ?? true;
    _startOnTimetable = prefs.getBool(_startOnTimetableKey) ?? false;
    _marketIsListView = prefs.getBool(_marketIsListViewKey) ?? false;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nightModeKey, _isDarkMode);
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    _isDarkMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nightModeKey, value);
    notifyListeners();
  }

  Future<void> setBackgroundImage(
    String? imageUrl, {
    bool fillScreen = false,
  }) async {
    _backgroundImage = imageUrl;
    _backgroundFillScreen =
        imageUrl != null && imageUrl.isNotEmpty ? fillScreen : false;
    final prefs = await SharedPreferences.getInstance();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      await prefs.setString(_backgroundImageKey, imageUrl);
      await prefs.setBool(_backgroundFillScreenKey, _backgroundFillScreen);
    } else {
      await prefs.remove(_backgroundImageKey);
      await prefs.remove(_backgroundFillScreenKey);
    }
    notifyListeners();
  }

  Future<void> setLandscapeBackgroundImage(
    String? imageUrl, {
    bool fillScreen = false,
  }) async {
    _landscapeBackgroundImage = imageUrl;
    _landscapeBackgroundFillScreen =
        imageUrl != null && imageUrl.isNotEmpty ? fillScreen : false;
    final prefs = await SharedPreferences.getInstance();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      await prefs.setString(_landscapeBackgroundImageKey, imageUrl);
      await prefs.setBool(
        _landscapeBackgroundFillScreenKey,
        _landscapeBackgroundFillScreen,
      );
    } else {
      await prefs.remove(_landscapeBackgroundImageKey);
      await prefs.remove(_landscapeBackgroundFillScreenKey);
    }
    notifyListeners();
  }

  Future<void> setBackgroundBlur(double blur) async {
    _backgroundBlur = blur.clamp(0, 30);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_backgroundBlurKey, _backgroundBlur);
    notifyListeners();
  }

  Future<void> setComponentOpacity(double value) async {
    _componentOpacity = value.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_componentOpacityKey, _componentOpacity);
    notifyListeners();
  }

  Future<void> setLiquidGlass(bool value) async {
    _liquidGlass = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liquidGlassKey, value);
    notifyListeners();
  }

  Future<void> setFloatingNavBar(bool value) async {
    _floatingNavBar = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_floatingNavBarKey, value);
    notifyListeners();
  }

  Future<void> setPredictiveBack(bool value) async {
    _predictiveBack = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_predictiveBackKey, value);
    notifyListeners();
  }

  Future<void> clearBackground() async {
    _backgroundImage = null;
    _landscapeBackgroundImage = null;
    _backgroundFillScreen = false;
    _landscapeBackgroundFillScreen = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_backgroundImageKey);
    await prefs.remove(_landscapeBackgroundImageKey);
    await prefs.remove(_backgroundFillScreenKey);
    await prefs.remove(_landscapeBackgroundFillScreenKey);
    notifyListeners();
  }

  Future<void> setStartOnTimetable(bool v) async {
    _startOnTimetable = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_startOnTimetableKey, v);
    notifyListeners();
  }

  Future<void> setMarketIsListView(bool v) async {
    _marketIsListView = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_marketIsListViewKey, v);
    notifyListeners();
  }
}
