import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app_platform.dart';


class SecretTooLargeException implements Exception {
  final int size;
  const SecretTooLargeException(this.size);
  @override
  String toString() => 'SecretTooLargeException: $size bytes (limit is 1024 bytes)';
}

/// 统一敏感数据安全存储接口（适合保存 Token、密码、API Key 等小数据，限制 1024 字节）
abstract interface class AppSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// 根据当前平台返回最佳实现的工厂方法
  factory AppSecretStore.current() {
    if (AppPlatforms.current.isOhos) {
      return const OhosAssetSecretStore();
    }
    if (kIsWeb) {
      return WebSecretStore();
    }
    return const FlutterDefaultSecretStore();
  }
}

/// Android / iOS 默认使用的 flutter_secure_storage
class FlutterDefaultSecretStore implements AppSecretStore {
  const FlutterDefaultSecretStore();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    if (utf8.encode(value).length > 1024) {
      return Future.error(SecretTooLargeException(utf8.encode(value).length));
    }
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 鸿蒙使用的 Asset Store Kit 桥接 (单条严格限制 < 1KB)
class OhosAssetSecretStore implements AppSecretStore {
  const OhosAssetSecretStore();
  static const _channel = MethodChannel('shenliyuan/secure_storage');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) {
    if (utf8.encode(value).length > 1024) {
      return Future.error(SecretTooLargeException(utf8.encode(value).length));
    }
    return _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}

/// Web 不持久化敏感凭据。认证由服务端 HttpOnly Cookie 维持，避免把 JWT
/// 放入 localStorage/IndexedDB 后被任意脚本直接读取。
class WebSecretStore implements AppSecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    if (utf8.encode(value).length > 1024) {
      throw SecretTooLargeException(utf8.encode(value).length);
    }
  }

  @override
  Future<void> delete(String key) async {}
}

/// 测试用内存存储
class MemorySecretStore implements AppSecretStore {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    if (utf8.encode(value).length > 1024) {
      throw SecretTooLargeException(utf8.encode(value).length);
    }
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);
}
