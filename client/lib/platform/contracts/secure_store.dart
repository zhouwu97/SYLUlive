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

/// 安全存储故障分类，用于区分“重试可能成功”和“密文已不可恢复”。
enum SecretStoreFailureKind {
  /// KeyStore 繁忙、MethodChannel 抖动等临时故障；保留数据并短暂重试。
  transient,

  /// 密文与当前密钥永久失配（BadPadding/BAD_DECRYPT、密钥丢失等）；
  /// 重试不可能成功，受影响的键只能删除后由用户重新建立。
  corruptedCiphertext,
}

/// Android KeyStore 与密文永久失配时的错误文本特征（不区分大小写）。
///
/// flutter_secure_storage 在 Android 上会把 Java 原始异常与完整堆栈放进
/// PlatformException（9.2.x 的 code 为 "Exception encountered"，message 只是
/// 方法名，BadPaddingException 等出现在 details 的堆栈文本里），因此必须把
/// details 一并纳入匹配。KeyStoreException 等可能由临时原因触发，不在此列，
/// 未命中签名时一律按临时故障处理，避免误删可恢复数据。
const List<String> _corruptedCiphertextSignatures = <String>[
  'badpaddingexception',
  'aeadbadtagexception',
  'badtagexception',
  'illegalblocksizeexception',
  'invalidkeyexception',
  'invalidkeyspecexception',
  'invalidalgorithmparameterexception',
  'unrecoverablekeyexception',
  'keypermanentlyinvalidatedexception',
  'bad_decrypt',
  'bad decrypt',
  'failed to unwrap key',
  'keystore corrupted',
];

SecretStoreFailureKind classifySecretStoreFailure(Object error) {
  final text = switch (error) {
    PlatformException(:final code, :final message, :final details) =>
      '$code\n${message ?? ''}\n${details ?? ''}'.toLowerCase(),
    _ => error.toString().toLowerCase(),
  };
  for (final signature in _corruptedCiphertextSignatures) {
    if (text.contains(signature)) {
      return SecretStoreFailureKind.corruptedCiphertext;
    }
  }
  return SecretStoreFailureKind.transient;
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
