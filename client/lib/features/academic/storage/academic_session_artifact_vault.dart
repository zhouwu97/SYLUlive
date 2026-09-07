import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../../../platform/contracts/secure_store.dart';
import '../domain/academic_provider.dart';

/// 会话密文文件后端；文件内容始终是 AEAD envelope，不保存明文 Cookie。
abstract interface class AcademicSessionArtifactFileBackend {
  Future<Uint8List?> read(String storageId);
  Future<void> write(String storageId, Uint8List bytes);
  Future<void> delete(String storageId);
}

final class MemoryAcademicSessionArtifactFileBackend
    implements AcademicSessionArtifactFileBackend {
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String storageId) async {
    final bytes = _files[storageId];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String storageId, Uint8List bytes) async {
    _files[storageId] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String storageId) async {
    _files.remove(storageId);
  }
}

final class PlatformAcademicSessionArtifactFileBackend
    implements AcademicSessionArtifactFileBackend {
  const PlatformAcademicSessionArtifactFileBackend();

  Future<String> _filePath(String storageId) async {
    final directory = await getApplicationSupportDirectory();
    return path.join(directory.path, 'academic_sessions', '$storageId.bin');
  }

  @override
  Future<Uint8List?> read(String storageId) async {
    final file = File(await _filePath(storageId));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(String storageId, Uint8List bytes) async {
    final file = File(await _filePath(storageId));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String storageId) async {
    final file = File(await _filePath(storageId));
    if (await file.exists()) await file.delete();
  }
}

/// Provider Session Artifact 的本地 AEAD 保险箱。
final class AcademicSessionArtifactVault {
  AcademicSessionArtifactVault({
    required this.identity,
    AppSecretStore? secretStore,
    AcademicSessionArtifactFileBackend? fileBackend,
    Uint8List Function(int length)? randomBytes,
  })  : _secretStore = secretStore ?? AppSecretStore.current(),
        _fileBackend =
            fileBackend ?? const PlatformAcademicSessionArtifactFileBackend(),
        _randomBytes = randomBytes ?? _secureRandomBytes;

  static const _keyLength = 32;
  static const _nonceLength = 12;
  static const _tagBits = 128;
  static const _envelopeVersion = 1;

  final AcademicIdentityKey identity;
  final AppSecretStore _secretStore;
  final AcademicSessionArtifactFileBackend _fileBackend;
  final Uint8List Function(int length) _randomBytes;

  String get _keyName => 'academic_session_dek_${identity.storageId}';

  Future<void> write(ProviderSessionArtifact artifact) async {
    _validateIdentity(artifact);
    final payload = jsonEncode(<String, Object?>{
      'provider_id': artifact.providerId.value,
      'student_id': artifact.studentId,
      'artifact_version': artifact.artifactVersion,
      'created_at': artifact.createdAt.toUtc().toIso8601String(),
      'validated_at': artifact.validatedAt?.toUtc().toIso8601String(),
      'max_restore_age_seconds': artifact.maxRestoreAge?.inSeconds,
      'opaque_provider_state': artifact.opaqueProviderState,
    });
    final nonce = _randomBytes(_nonceLength);
    if (nonce.length != _nonceLength) throw const FormatException('会话密文随机数生成失败');
    final key = await _loadOrCreateKey();
    final ciphertext = _crypt(
      encrypting: true,
      key: key,
      nonce: nonce,
      input: Uint8List.fromList(utf8.encode(payload)),
    );
    final envelope = jsonEncode(<String, Object?>{
      'envelope_version': _envelopeVersion,
      'identity_storage_id': identity.storageId,
      'provider_id': identity.providerId.value,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(ciphertext),
    });
    await _fileBackend.write(
      identity.storageId,
      Uint8List.fromList(utf8.encode(envelope)),
    );
  }

  Future<ProviderSessionArtifact?> read() async {
    final bytes = await _fileBackend.read(identity.storageId);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final envelopeValue = jsonDecode(utf8.decode(bytes));
      if (envelopeValue is! Map) throw const FormatException('会话密文信封格式无效');
      final envelope = Map<String, dynamic>.from(envelopeValue);
      if (envelope['envelope_version'] != _envelopeVersion ||
          envelope['identity_storage_id'] != identity.storageId ||
          envelope['provider_id'] != identity.providerId.value) {
        throw const FormatException('会话密文身份校验失败');
      }
      final nonce = base64Decode(envelope['nonce'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      if (nonce.length != _nonceLength || ciphertext.length <= _tagBits ~/ 8) {
        throw const FormatException('会话密文参数无效');
      }
      final plaintext = _crypt(
        encrypting: false,
        key: await _readKey(),
        nonce: nonce,
        input: ciphertext,
      );
      final value = jsonDecode(utf8.decode(plaintext));
      if (value is! Map) throw const FormatException('会话材料结构无效');
      final record = Map<String, dynamic>.from(value);
      final provider = AcademicProviderId.tryParse(
        record['provider_id']?.toString() ?? '',
      );
      if (provider == null ||
          provider != identity.providerId ||
          record['student_id']?.toString() != identity.studentId) {
        throw const FormatException('会话材料身份不匹配');
      }
      final createdAt = DateTime.tryParse(record['created_at']?.toString() ?? '');
      if (createdAt == null || record['opaque_provider_state'] is! Map) {
        throw const FormatException('会话材料字段无效');
      }
      final maxAgeSeconds = record['max_restore_age_seconds'];
      return ProviderSessionArtifact(
        providerId: provider,
        studentId: identity.studentId,
        artifactVersion: record['artifact_version'] as int,
        createdAt: createdAt,
        validatedAt: DateTime.tryParse(record['validated_at']?.toString() ?? ''),
        maxRestoreAge: maxAgeSeconds is int
            ? Duration(seconds: maxAgeSeconds)
            : null,
        opaqueProviderState:
            Map<String, Object?>.from(record['opaque_provider_state'] as Map),
      );
    } catch (_) {
      // 损坏或跨身份密文不能继续尝试恢复，清除后由密码重新建立会话。
      await delete();
      return null;
    }
  }

  Future<void> delete() async {
    await _fileBackend.delete(identity.storageId);
    await _secretStore.delete(_keyName);
  }

  Future<Uint8List> _loadOrCreateKey() async {
    final existing = await _readKeyOrNull();
    if (existing != null) return existing;
    final generated = _randomBytes(_keyLength);
    if (generated.length != _keyLength) throw const FormatException('会话密钥生成失败');
    await _secretStore.write(_keyName, base64Encode(generated));
    return generated;
  }

  Future<Uint8List> _readKey() async =>
      await _readKeyOrNull() ?? (throw const FormatException('会话密钥不可用'));

  Future<Uint8List?> _readKeyOrNull() async {
    final raw = await _secretStore.read(_keyName);
    if (raw == null || raw.isEmpty) return null;
    final decoded = base64Decode(raw);
    if (decoded.length != _keyLength) throw const FormatException('会话密钥长度无效');
    return Uint8List.fromList(decoded);
  }

  Uint8List _crypt({
    required bool encrypting,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List input,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypting,
        AEADParameters(
          KeyParameter(key),
          _tagBits,
          nonce,
          Uint8List.fromList(utf8.encode('${identity.canonical}|$_envelopeVersion')),
        ),
      );
    return cipher.process(input);
  }

  void _validateIdentity(ProviderSessionArtifact artifact) {
    if (!identity.isValid ||
        artifact.providerId != identity.providerId ||
        artifact.studentId.trim() != identity.studentId.trim()) {
      throw const FormatException('会话材料身份不匹配');
    }
  }

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
