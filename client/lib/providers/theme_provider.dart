import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _nightModeKey = 'night_mode';
  static const String _backgroundImageKey = 'background_image';
  static const String _backgroundBlurKey = 'background_blur';
  static const String _componentOpacityKey = 'background_transparency'; // 保持 key 兼容
  static const String _liquidGlassKey = 'liquid_glass';
  static const String _floatingNavBarKey = 'floating_nav_bar';

  bool _isDarkMode = false;
  String? _backgroundImage;
  double _backgroundBlur = 10;
  double _componentOpacity = 0.7;  // 组件不透明度：越大越实，越小越透
  bool _liquidGlass = true;
  bool _floatingNavBar = false;

  bool get isDarkMode => _isDarkMode;
  String? get backgroundImage => _backgroundImage;
  double get backgroundBlur => _backgroundBlur;
  double get componentOpacity => _componentOpacity;
  bool get liquidGlass => _liquidGlass;
  bool get floatingNavBar => _floatingNavBar;
  bool get hasBackground => _backgroundImage != null && _backgroundImage!.isNotEmpty;

  /// 是否有自定义背景（全局生效）
  bool get isBackgroundVisible => hasBackground;

  ThemeProvider() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_nightModeKey) ?? false;
    _backgroundImage = prefs.getString(_backgroundImageKey);
    _backgroundBlur = prefs.getDouble(_backgroundBlurKey) ?? 10;
    _componentOpacity = prefs.getDouble(_componentOpacityKey) ?? 0.7;
    _liquidGlass = prefs.getBool(_liquidGlassKey) ?? true;
    _floatingNavBar = prefs.getBool(_floatingNavBarKey) ?? false;
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

  Future<void> setBackgroundImage(String? imageUrl) async {
    _backgroundImage = imageUrl;
    final prefs = await SharedPreferences.getInstance();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      await prefs.setString(_backgroundImageKey, imageUrl);
    } else {
      await prefs.remove(_backgroundImageKey);
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

  Future<void> clearBackground() async {
    _backgroundImage = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_backgroundImageKey);
    notifyListeners();
  }
}
