import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_platform.dart';

/// 统一安全存储接口
abstract interface class AppSecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// 根据当前平台返回最佳实现的工厂方法
  factory AppSecureStore.current() {
    if (AppPlatforms.current.isOhos) {
      return const OhosAssetSecureStore();
    }
    if (kIsWeb) {
      return WebSecureStore();
    }
    return const FlutterDefaultSecureStore();
  }
}

/// Android / iOS 默认使用的 flutter_secure_storage
class FlutterDefaultSecureStore implements AppSecureStore {
  const FlutterDefaultSecureStore();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 鸿蒙使用的 Asset Store Kit 桥接
class OhosAssetSecureStore implements AppSecureStore {
  const OhosAssetSecureStore();
  static const _channel = MethodChannel('shenliyuan/secure_storage');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}

/// Web 环境使用的兜底持久化（由于无法使用系统级 KeyStore）
class WebSecureStore implements AppSecureStore {
  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// 测试用内存存储
class MemorySecureStore implements AppSecureStore {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);
}
