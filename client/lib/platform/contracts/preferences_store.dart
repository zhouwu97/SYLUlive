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
  static Future<AppPreferencesStore>? _loading;

  static Future<AppPreferencesStore> getInstance() {
    if (_instance != null) return Future.value(_instance!);
    return _loading ??= _create().catchError((Object error) {
      _loading = null;
      throw error;
    });
  }

  /// 已初始化的存储实例；尚未初始化时为 null。
  ///
  /// 供启动关键路径同步读取（如主题首帧加载），避免等异步初始化造成
  /// 首帧后外观跳变。为 null 时调用方应回退到 [getInstance] 异步路径。
  static AppPreferencesStore? get maybeInstance => _instance;

  static Future<AppPreferencesStore> _create() async {
    AppPreferencesStore store;
    if (AppPlatforms.current == AppPlatform.ohos) {
      final ohosStore = OhosPreferencesStore();
      await ohosStore.init();
      store = ohosStore;
    } else {
      final prefs = await SharedPreferences.getInstance();
      store = SharedPreferencesStore(prefs);
    }
    _instance = store;
    return store;
  }

  /// 供测试使用：设置模拟的初始值
  static void setMockInitialValues(Map<String, Object> values) {
    // 该入口只服务于测试基线；SharedPreferences 将其标记为测试可见 API。
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(values);
    _instance = null;
    _loading = null;
  }
}

/// shared_preferences 在 Android、iOS、macOS 和 Windows 都提供同一套
/// key-value 语义；这里不再把跨平台实现命名为 Android 专属。
class SharedPreferencesStore implements AppPreferencesStore {
  final SharedPreferences _prefs;
  const SharedPreferencesStore(this._prefs);

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);

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
  Future<bool> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  @override
  List<String>? getStringList(String key) => _prefs.getStringList(key);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);

  @override
  Future<bool> clear() => _prefs.clear();

  @override
  bool containsKey(String key) => _prefs.containsKey(key);

  @override
  Set<String> getKeys() => _prefs.getKeys();
}

@Deprecated('Use SharedPreferencesStore')
typedef AndroidPreferencesStore = SharedPreferencesStore;

class OhosPreferencesStore implements AppPreferencesStore {
  static const _channel = MethodChannel('shenliyuan/preferences');
  final Map<String, dynamic> _cache = {};

  OhosPreferencesStore();

  Future<void> init() async {
    final all = await _channel.invokeMethod<Map<dynamic, dynamic>>('getAll');
    if (all != null) {
      _cache.clear();
      for (final entry in all.entries) {
        final value = entry.value;
        if (value is List) {
          _cache[entry.key as String] =
              List<String>.unmodifiable(value.cast<String>());
        } else {
          _cache[entry.key as String] = value;
        }
      }
    } else {
      throw StateError(
          'Failed to initialize OhosPreferencesStore: getAll returned null');
    }
  }

  @override
  String? getString(String key) => _cache[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    try {
      await _channel
          .invokeMethod<void>('setString', {'key': key, 'value': value});
      _cache[key] = value;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool? getBool(String key) => _cache[key] as bool?;

  @override
  Future<bool> setBool(String key, bool value) async {
    try {
      await _channel
          .invokeMethod<void>('setBool', {'key': key, 'value': value});
      _cache[key] = value;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  int? getInt(String key) {
    final value = _cache[key];
    return value is num ? value.toInt() : null;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    try {
      await _channel.invokeMethod<void>('setInt', {'key': key, 'value': value});
      _cache[key] = value;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  double? getDouble(String key) {
    final value = _cache[key];
    return value is num ? value.toDouble() : null;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    try {
      await _channel
          .invokeMethod<void>('setDouble', {'key': key, 'value': value});
      _cache[key] = value;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  List<String>? getStringList(String key) {
    final list = _cache[key] as List<dynamic>?;
    return list?.cast<String>().toList();
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    try {
      await _channel
          .invokeMethod<void>('setStringList', {'key': key, 'value': value});
      _cache[key] = List<String>.unmodifiable(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> remove(String key) async {
    try {
      await _channel.invokeMethod<void>('remove', {'key': key});
      _cache.remove(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
      _cache.clear();
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
  int? getInt(String key) {
    final value = _values[key];
    return value is num ? value.toInt() : null;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _values[key] = value;
    return true;
  }

  @override
  double? getDouble(String key) {
    final value = _values[key];
    return value is num ? value.toDouble() : null;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _values[key] = value;
    return true;
  }

  @override
  List<String>? getStringList(String key) {
    final list = _values[key] as List<dynamic>?;
    return list?.cast<String>().toList();
  }

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
