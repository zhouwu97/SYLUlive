import 'dart:convert';
import 'dart:io';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:path_provider/path_provider.dart';

import 'secure_store.dart';

abstract interface class AppBlobStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 针对大文本（大于1024字节）的加密存储。
/// 使用 AppSecretStore 保存随机生成的 AES 密钥，并将加密后的密文存储到沙盒私有文件中。
class EncryptedBlobStore implements AppBlobStore {
  final AppSecretStore _secretStore;
  final String _namespace;

  EncryptedBlobStore({
    AppSecretStore? secretStore,
    String namespace = 'default',
  })  : _secretStore = secretStore ?? AppSecretStore.current(),
        _namespace = namespace;

  String get _keyStoreName => 'blob_aes_key_$_namespace';

  Future<enc.Key> _getOrCreateKey() async {
    final existingBase64 = await _secretStore.read(_keyStoreName);
    if (existingBase64 != null && existingBase64.isNotEmpty) {
      return enc.Key.fromBase64(existingBase64);
    }
    final newKey = enc.Key.fromSecureRandom(32); // 256 bit
    await _secretStore.write(_keyStoreName, newKey.base64);
    return newKey;
  }

  Future<File> _getFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory('${dir.path}/vault/$_namespace');
    if (!await vaultDir.exists()) {
      await vaultDir.create(recursive: true);
    }
    // 防止 key 里包含非法文件路径字符
    final safeKey = base64Url.encode(utf8.encode(key));
    return File('${vaultDir.path}/$safeKey.enc');
  }

  @override
  Future<void> write(String key, String value) async {
    final aesKey = await _getOrCreateKey();
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));

    final encrypted = encrypter.encrypt(value, iv: iv);

    // 我们需要将 IV 和密文一起保存
    final combined = '${iv.base64}:${encrypted.base64}';
    final file = await _getFile(key);
    final tempFile = File('${file.path}.tmp');

    await tempFile.writeAsString(combined, flush: true);
    await tempFile.rename(file.path);
  }

  @override
  Future<String?> read(String key) async {
    final file = await _getFile(key);
    if (!await file.exists()) {
      return null;
    }
    final content = await file.readAsString();
    final parts = content.split(':');
    if (parts.length != 2) throw const FormatException('Invalid blob format');

    final aesKey = await _getOrCreateKey();
    final iv = enc.IV.fromBase64(parts[0]);
    final encryptedData = enc.Encrypted.fromBase64(parts[1]);

    final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));
    try {
      return encrypter.decrypt(encryptedData, iv: iv);
    } catch (e) {
      throw FormatException('Decryption failed: $e');
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = await _getFile(key);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class MemoryBlobStore implements AppBlobStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
