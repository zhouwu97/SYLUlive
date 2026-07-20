import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'account_cache_namespace.dart';
import 'personal_snapshot_file_backend.dart';
import 'personal_snapshot_file_backend_base.dart';
import 'personal_snapshot_models.dart';

abstract interface class PersonalSnapshotSecureStore {
  Future<String?> read(String key);
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterPersonalSnapshotSecureStore
    implements PersonalSnapshotSecureStore {
  const FlutterPersonalSnapshotSecureStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

abstract interface class AccountScopedSnapshotStore {
  String get accountFingerprint;

  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  });

  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  });

  Future<void> deleteType(PersonalDataType type);

  /// 先删除账号密钥，再删除密文，形成加密擦除。
  Future<void> clearUser();

  Future<void> close();
}

/// AES-256-GCM 文件保险箱。
///
/// 数据密钥和设备盐只存在 FlutterSecureStorage；文件系统只保存密文信封。
class AesGcmAccountScopedSnapshotStore implements AccountScopedSnapshotStore {
  AesGcmAccountScopedSnapshotStore({
    required String appUserId,
    PersonalSnapshotSecureStore secureStore =
        const FlutterPersonalSnapshotSecureStore(),
    PersonalSnapshotFileBackend? fileBackend,
    Uint8List Function(int length)? randomBytes,
  })  : _accountHash = _validateAccount(appUserId),
        _secureStore = secureStore,
        _fileBackend = fileBackend ?? createPersonalSnapshotFileBackend(),
        _randomBytes = randomBytes ?? _secureRandomBytes;

  static const int encryptionVersion = 1;
  static const int envelopeVersion = 1;
  static const int _keyLength = 32;
  static const int _nonceLength = 12;
  static const int _tagBits = 128;
  static const int _maxPayloadBytes = 10 * 1024 * 1024;
  static const String _keyPrefix = 'ai_personal_vault_key/';
  static const String _deviceSaltKey = 'ai_personal_vault_device_salt/v1';

  static final Map<String, Future<Uint8List>> _inFlightSecrets =
      <String, Future<Uint8List>>{};

  final String _accountHash;
  final PersonalSnapshotSecureStore _secureStore;
  final PersonalSnapshotFileBackend _fileBackend;
  final Uint8List Function(int length) _randomBytes;

  @override
  String get accountFingerprint => _accountHash;

  String get _accountKey => '$_keyPrefix$_accountHash/v1';

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {
    if (schemaVersion < 1) {
      throw const PersonalSnapshotStoreException('个人数据 SchemaVersion 必须大于 0');
    }
    final normalizedSystem = sourceSystem.trim().toLowerCase();
    final normalizedAccount = sourceAccountId.trim().toLowerCase();
    if (normalizedSystem.isEmpty || normalizedAccount.isEmpty) {
      throw const PersonalSnapshotStoreException('个人数据缺少可校验的来源账号');
    }

    final payloadJson = jsonEncode(payload);
    final payloadBytes = utf8.encode(payloadJson);
    if (payloadBytes.length > _maxPayloadBytes) {
      throw const PersonalSnapshotStoreException('个人数据快照超过本地容量限制');
    }
    final contentHash = sha256.convert(payloadBytes).toString();
    final sourceFingerprint = await _sourceFingerprintForWrite(
      normalizedSystem,
      normalizedAccount,
    );
    final fetchedAtUtc = (fetchedAt ?? DateTime.now()).toUtc();
    final expiresAtUtc = expiresAt?.toUtc();

    final plaintext = jsonEncode(<String, dynamic>{
      'app_user_id': _accountHash,
      'source_account_fingerprint': sourceFingerprint,
      'data_type': type.storageValue,
      'schema_version': schemaVersion,
      'encryption_version': encryptionVersion,
      'fetched_at': fetchedAtUtc.toIso8601String(),
      'expires_at': expiresAtUtc?.toIso8601String(),
      'content_hash': contentHash,
      'payload_json': payloadJson,
    });

    final key = await _loadOrCreateSecret(
      keyName: _accountKey,
      expectedLength: _keyLength,
    );
    final nonce = _randomBytes(_nonceLength);
    if (nonce.length != _nonceLength) {
      throw const PersonalSnapshotStoreException('无法生成个人数据加密随机数');
    }
    final ciphertext = _processGcm(
      encrypting: true,
      key: key,
      nonce: nonce,
      aad: _aad(type),
      input: Uint8List.fromList(utf8.encode(plaintext)),
    );

    final envelope = jsonEncode(<String, dynamic>{
      'envelope_version': envelopeVersion,
      'encryption_version': encryptionVersion,
      'account_hash': _accountHash,
      'data_type': type.storageValue,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
    });
    await _fileBackend.write(
      accountHash: _accountHash,
      type: type,
      bytes: Uint8List.fromList(utf8.encode(envelope)),
    );
  }

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) async {
    final encrypted = await _fileBackend.read(
      accountHash: _accountHash,
      type: type,
    );
    if (encrypted == null || encrypted.isEmpty) return null;

    try {
      final envelopeValue = jsonDecode(utf8.decode(encrypted));
      if (envelopeValue is! Map) {
        throw const FormatException('密文信封格式错误');
      }
      final envelope = Map<String, dynamic>.from(envelopeValue);
      _validateEnvelope(envelope, type);

      final key = await _readExistingSecret(
        keyName: _accountKey,
        expectedLength: _keyLength,
      );
      if (key == null) {
        throw const PersonalSnapshotStoreException('个人数据密钥不可用，已拒绝读取本地密文');
      }

      final nonce = base64Decode(envelope['nonce'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      if (nonce.length != _nonceLength || ciphertext.length <= _tagBits ~/ 8) {
        throw const FormatException('密文参数错误');
      }
      final plaintext = _processGcm(
        encrypting: false,
        key: key,
        nonce: nonce,
        aad: _aad(type),
        input: ciphertext,
      );

      final recordValue = jsonDecode(utf8.decode(plaintext));
      if (recordValue is! Map) {
        throw const FormatException('个人数据内容格式错误');
      }
      final record = Map<String, dynamic>.from(recordValue);
      _validateRecord(record, type);

      final expectedSource = await _sourceFingerprintForRead(
        sourceSystem.trim().toLowerCase(),
        sourceAccountId.trim().toLowerCase(),
      );
      if (record['source_account_fingerprint'] != expectedSource) {
        return null;
      }

      final payloadJson = record['payload_json'] as String;
      final actualHash = sha256.convert(utf8.encode(payloadJson)).toString();
      if (record['content_hash'] != actualHash) {
        throw const FormatException('个人数据内容哈希不匹配');
      }
      final payloadValue = jsonDecode(payloadJson);
      if (payloadValue is! Map) {
        throw const FormatException('个人数据 Payload 格式错误');
      }

      final fetchedAt = DateTime.tryParse(
        record['fetched_at'] as String,
      )?.toUtc();
      final expiresAtValue = record['expires_at'];
      final expiresAt = expiresAtValue == null
          ? null
          : DateTime.tryParse(expiresAtValue as String)?.toUtc();
      if (fetchedAt == null || (expiresAtValue != null && expiresAt == null)) {
        throw const FormatException('个人数据时间格式错误');
      }

      return PersonalSnapshot(
        appUserFingerprint: _accountHash,
        sourceAccountFingerprint:
            record['source_account_fingerprint'] as String,
        type: type,
        schemaVersion: record['schema_version'] as int,
        encryptionVersion: encryptionVersion,
        fetchedAt: fetchedAt,
        expiresAt: expiresAt,
        contentHash: actualHash,
        payload: Map<String, dynamic>.from(payloadValue),
      );
    } on PersonalSnapshotStoreException {
      rethrow;
    } on InvalidCipherTextException {
      throw const PersonalSnapshotStoreException('个人数据密文认证失败，已拒绝读取');
    } on FormatException {
      throw const PersonalSnapshotStoreException('个人数据密文无效，已拒绝读取');
    } catch (_) {
      throw const PersonalSnapshotStoreException('个人数据读取失败，已拒绝使用');
    }
  }

  @override
  Future<void> deleteType(PersonalDataType type) {
    return _fileBackend.deleteType(accountHash: _accountHash, type: type);
  }

  @override
  Future<void> clearUser() async {
    // 先删除密钥；即使文件清理失败，残留密文也无法继续解密。
    await _secureStore.delete(_accountKey);
    await _fileBackend.deleteUser(_accountHash);
  }

  /// 仅用于“清除全部本地个人数据”设置项，不删除其他业务密钥。
  static Future<void> clearAllVaultData({
    PersonalSnapshotSecureStore secureStore =
        const FlutterPersonalSnapshotSecureStore(),
    PersonalSnapshotFileBackend? fileBackend,
  }) async {
    final values = await secureStore.readAll();
    final keys = values.keys
        .where((key) => key.startsWith(_keyPrefix) || key == _deviceSaltKey)
        .toList();
    for (final key in keys) {
      await secureStore.delete(key);
    }
    await (fileBackend ?? createPersonalSnapshotFileBackend()).deleteAll();
  }

  @override
  Future<void> close() async {
    // 密钥不在实例中缓存；每次操作结束后 Vault 即处于关闭状态。
  }

  Future<String> _sourceFingerprintForWrite(
    String sourceSystem,
    String sourceAccountId,
  ) async {
    _validateSource(sourceSystem, sourceAccountId);
    final salt = await _loadOrCreateSecret(
      keyName: _deviceSaltKey,
      expectedLength: _keyLength,
    );
    return _hashSource(sourceSystem, sourceAccountId, salt);
  }

  Future<String> _sourceFingerprintForRead(
    String sourceSystem,
    String sourceAccountId,
  ) async {
    _validateSource(sourceSystem, sourceAccountId);
    final salt = await _readExistingSecret(
      keyName: _deviceSaltKey,
      expectedLength: _keyLength,
    );
    if (salt == null) {
      throw const PersonalSnapshotStoreException('个人数据设备盐不可用，已拒绝读取本地密文');
    }
    return _hashSource(sourceSystem, sourceAccountId, salt);
  }

  String _hashSource(
    String sourceSystem,
    String sourceAccountId,
    Uint8List salt,
  ) {
    final material = '$sourceSystem|$sourceAccountId|${base64Encode(salt)}';
    return sha256.convert(utf8.encode(material)).toString();
  }

  void _validateSource(String sourceSystem, String sourceAccountId) {
    if (sourceSystem.isEmpty || sourceAccountId.isEmpty) {
      throw const PersonalSnapshotStoreException('个人数据缺少可校验的来源账号');
    }
  }

  Future<Uint8List> _loadOrCreateSecret({
    required String keyName,
    required int expectedLength,
  }) async {
    final inFlightKey = '${identityHashCode(_secureStore)}|$keyName';
    final inFlight = _inFlightSecrets[inFlightKey];
    if (inFlight != null) return Uint8List.fromList(await inFlight);

    final future = () async {
      final existing = await _decodeSecret(keyName, expectedLength);
      if (existing != null) return existing;

      final generated = _randomBytes(expectedLength);
      if (generated.length != expectedLength) {
        throw const PersonalSnapshotStoreException('无法生成个人数据安全密钥');
      }
      await _secureStore.write(keyName, base64Encode(generated));
      final verified = await _decodeSecret(keyName, expectedLength);
      if (verified == null) {
        throw const PersonalSnapshotStoreException('个人数据安全密钥保存失败');
      }
      return verified;
    }();
    _inFlightSecrets[inFlightKey] = future;

    try {
      final value = await future;
      return Uint8List.fromList(value);
    } finally {
      _inFlightSecrets.remove(inFlightKey);
    }
  }

  Future<Uint8List?> _readExistingSecret({
    required String keyName,
    required int expectedLength,
  }) {
    return _decodeSecret(keyName, expectedLength);
  }

  Future<Uint8List?> _decodeSecret(String keyName, int expectedLength) async {
    final raw = await _secureStore.read(keyName);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = base64Decode(raw);
      if (decoded.length != expectedLength) {
        throw const FormatException('安全密钥长度错误');
      }
      return decoded;
    } on FormatException {
      throw const PersonalSnapshotStoreException('个人数据安全密钥无效');
    }
  }

  void _validateEnvelope(Map<String, dynamic> envelope, PersonalDataType type) {
    final valid = envelope['envelope_version'] == envelopeVersion &&
        envelope['encryption_version'] == encryptionVersion &&
        envelope['account_hash'] == _accountHash &&
        envelope['data_type'] == type.storageValue &&
        envelope['nonce'] is String &&
        envelope['ciphertext'] is String;
    if (!valid) {
      throw const FormatException('密文信封归属校验失败');
    }
  }

  void _validateRecord(Map<String, dynamic> record, PersonalDataType type) {
    final valid = record['app_user_id'] == _accountHash &&
        record['data_type'] == type.storageValue &&
        record['schema_version'] is int &&
        (record['schema_version'] as int) > 0 &&
        record['encryption_version'] == encryptionVersion &&
        record['source_account_fingerprint'] is String &&
        record['fetched_at'] is String &&
        (record['expires_at'] == null || record['expires_at'] is String) &&
        record['content_hash'] is String &&
        record['payload_json'] is String;
    if (!valid) {
      throw const FormatException('个人数据内容归属校验失败');
    }
  }

  Uint8List _aad(PersonalDataType type) {
    return Uint8List.fromList(
      utf8.encode(
        '$_accountHash|${type.storageValue}|'
        '$envelopeVersion|$encryptionVersion',
      ),
    );
  }

  Uint8List _processGcm({
    required bool encrypting,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List input,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypting,
        AEADParameters(KeyParameter(key), _tagBits, nonce, aad),
      );
    return cipher.process(input);
  }

  static String _validateAccount(String appUserId) {
    final fingerprint = AccountCacheNamespace.fingerprint(appUserId);
    if (fingerprint.isEmpty) {
      throw ArgumentError.value(appUserId, 'appUserId');
    }
    return fingerprint;
  }

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
