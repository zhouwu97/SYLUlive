import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_platform.dart';

/// 统一偏好设置接口，解决鸿蒙端官方 shared_preferences 缺失问题
abstract interface class AppPreferencesStore {
  String? getString(String key);
  Future<bool> setString(String key, String value);
  bool? getBool(String key);
  Future<bool> setBool(String key, bool value);
  int? getInt(String key);
  Future<bool> setInt(String key, int value);
  double? getDouble(String key);
  Future<bool> setDouble(String key, double value);
  List<String>? getStringList(String key);
  Future<bool> setStringList(String key, List<String> value);
  Future<bool> remove(String key);
  Future<bool> clear();
  bool containsKey(String key);
  Set<String> getKeys();

  static AppPreferencesStore? _instance;

  static Future<AppPreferencesStore> getInstance() async {
    if (_instance != null) return _instance!;
    
    if (AppPlatforms.current == AppPlatform.ohos) {
      final store = OhosPreferencesStore();
      await store.init();
      _instance = store;
    } else {
      final prefs = await SharedPreferences.getInstance();
      _instance = AndroidPreferencesStore(prefs);
    }
    return _instance!;
  }

  /// 供测试使用：设置模拟的初始值
  static void setMockInitialValues(Map<String, Object> values) {
    SharedPreferences.setMockInitialValues(values);
    _instance = null;
  }
}

class AndroidPreferencesStore implements AppPreferencesStore {
  final SharedPreferences _prefs;
  const AndroidPreferencesStore(this._prefs);

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<bool> setString(String key, String value) => _prefs.setString(key, value);

  @override
  bool? getBool(String key) => _prefs.getBool(key);

  @override
  Future<bool> setBool(String key, bool value) => _prefs.setBool(key, value);

  @override
  int? getInt(String key) => _prefs.getInt(key);

  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  double? getDouble(String key) => _prefs.getDouble(key);

  @override
  Future<bool> setDouble(String key, double value) => _prefs.setDouble(key, value);

  @override
  List<String>? getStringList(String key) => _prefs.getStringList(key);

  @override
  Future<bool> setStringList(String key, List<String> value) => _prefs.setStringList(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);

  @override
  Future<bool> clear() => _prefs.clear();

  @override
  bool containsKey(String key) => _prefs.containsKey(key);

  @override
  Set<String> getKeys() => _prefs.getKeys();
}

class OhosPreferencesStore implements AppPreferencesStore {
  static const _channel = MethodChannel('shenliyuan/preferences');
  final Map<String, dynamic> _cache = {};

  OhosPreferencesStore();

  Future<void> init() async {
    try {
      final all = await _channel.invokeMethod<Map<dynamic, dynamic>>('getAll');
      if (all != null) {
        _cache.clear();
        for (final entry in all.entries) {
          _cache[entry.key as String] = entry.value;
        }
      }
    } catch (_) {}
  }

  @override
  String? getString(String key) => _cache[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    _cache[key] = value;
    try {
      await _channel.invokeMethod<void>('setString', {'key': key, 'value': value});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool? getBool(String key) => _cache[key] as bool?;

  @override
  Future<bool> setBool(String key, bool value) async {
    _cache[key] = value;
    try {
      await _channel.invokeMethod<void>('setBool', {'key': key, 'value': value});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  int? getInt(String key) => _cache[key] as int?;

  @override
  Future<bool> setInt(String key, int value) async {
    _cache[key] = value;
    try {
      await _channel.invokeMethod<void>('setInt', {'key': key, 'value': value});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  double? getDouble(String key) => _cache[key] as double?;

  @override
  Future<bool> setDouble(String key, double value) async {
    _cache[key] = value;
    try {
      await _channel.invokeMethod<void>('setDouble', {'key': key, 'value': value});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  List<String>? getStringList(String key) => (_cache[key] as List<dynamic>?)?.cast<String>();

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _cache[key] = value;
    try {
      await _channel.invokeMethod<void>('setStringList', {'key': key, 'value': value});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> remove(String key) async {
    _cache.remove(key);
    try {
      await _channel.invokeMethod<void>('remove', {'key': key});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    _cache.clear();
    try {
      await _channel.invokeMethod<void>('clear');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool containsKey(String key) => _cache.containsKey(key);

  @override
  Set<String> getKeys() => _cache.keys.toSet();
}

class MemoryPreferencesStore implements AppPreferencesStore {
  final Map<String, dynamic> _values = {};

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  Future<bool> setBool(String key, bool value) async {
    _values[key] = value;
    return true;
  }

  @override
  int? getInt(String key) => _values[key] as int?;

  @override
  Future<bool> setInt(String key, int value) async {
    _values[key] = value;
    return true;
  }

  @override
  double? getDouble(String key) => _values[key] as double?;

  @override
  Future<bool> setDouble(String key, double value) async {
    _values[key] = value;
    return true;
  }

  @override
  List<String>? getStringList(String key) => _values[key] as List<String>?;

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    _values.clear();
    return true;
  }

  @override
  bool containsKey(String key) => _values.containsKey(key);

  @override
  Set<String> getKeys() => _values.keys.toSet();
}
