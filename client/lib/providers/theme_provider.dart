import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BackgroundScope { global, meOnly }

class ThemeProvider extends ChangeNotifier {
  static const String _nightModeKey = 'night_mode';
  static const String _backgroundImageKey = 'background_image';
  static const String _backgroundBlurKey = 'background_blur';
  static const String _backgroundTransparencyKey = 'background_transparency';
  static const String _backgroundScopeKey = 'background_scope';
  static const String _liquidGlassKey = 'liquid_glass';
  static const String _floatingNavBarKey = 'floating_nav_bar';

  bool _isDarkMode = false;
  String? _backgroundImage;
  double _backgroundBlur = 10;
  double _backgroundTransparency = 0.5;
  BackgroundScope _backgroundScope = BackgroundScope.global;
  bool _liquidGlass = true;
  bool _floatingNavBar = false;

  bool get isDarkMode => _isDarkMode;
  String? get backgroundImage => _backgroundImage;
  double get backgroundBlur => _backgroundBlur;
  double get backgroundTransparency => _backgroundTransparency;
  BackgroundScope get backgroundScope => _backgroundScope;
  bool get liquidGlass => _liquidGlass;
  bool get floatingNavBar => _floatingNavBar;
  bool get hasBackground => _backgroundImage != null && _backgroundImage!.isNotEmpty;

  bool isBackgroundVisible(String screen) {
    if (!hasBackground) return false;
    if (_backgroundScope == BackgroundScope.global) return true;
    return screen == 'profile' || screen == 'messages' || screen == 'edu';
  }

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_nightModeKey) ?? false;
    _backgroundImage = prefs.getString(_backgroundImageKey);
    _backgroundBlur = prefs.getDouble(_backgroundBlurKey) ?? 10;
    _backgroundTransparency = prefs.getDouble(_backgroundTransparencyKey) ?? 0.5;
    _liquidGlass = prefs.getBool(_liquidGlassKey) ?? true;
    _floatingNavBar = prefs.getBool(_floatingNavBarKey) ?? false;

    final scopeIndex = prefs.getInt(_backgroundScopeKey) ?? 0;
    _backgroundScope = BackgroundScope.values[scopeIndex.clamp(0, BackgroundScope.values.length - 1)];

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

  Future<void> setBackgroundTransparency(double value) async {
    _backgroundTransparency = value.clamp(0, 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_backgroundTransparencyKey, _backgroundTransparency);
    notifyListeners();
  }

  Future<void> setBackgroundScope(BackgroundScope scope) async {
    _backgroundScope = scope;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_backgroundScopeKey, scope.index);
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