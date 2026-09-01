import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../platform/contracts/secure_store.dart';
import '../campus_data/storage/account_scoped_snapshot_store.dart';
import '../campus_data/storage/account_cache_namespace.dart';
import 'local_school_profile.dart';

/// Secure Storage 中保存的本地学校会话快照。
class LocalSchoolCredentialSnapshot {
  const LocalSchoolCredentialSnapshot({
    required this.studentId,
    this.password,
    this.cookie,
    this.sessionMetadata = const <String, dynamic>{},
  });

  final String studentId;
  final String? password;
  final String? cookie;
  final Map<String, dynamic> sessionMetadata;
}

class LocalSchoolVaultException implements Exception {
  const LocalSchoolVaultException(this.message);

  final String message;

  @override
  String toString() => 'LocalSchoolVaultException($message)';
}

/// Profile 专属安全存储。
///
/// 所有秘密都通过 [AppSecretStore] 写入 OS-backed secure storage；这里不引入
/// SharedPreferences、SQLite 或文件后端。AppSecretStore 单条值有 1 KiB 限制，
/// 因此 Cookie/元数据按小块编码后分别写入，仍不会落到普通文件系统。
class LocalSchoolCredentialVault {
  LocalSchoolCredentialVault({
    required this.profile,
    AppSecretStore? secureStore,
    AccountScopedSnapshotStore? snapshotStore,
  })  : _secureStore = secureStore ?? AppSecretStore.current(),
        _snapshotStore = snapshotStore ??
            AesGcmAccountScopedSnapshotStore(
              // 把 Profile UUID 纳入 Vault 账号指纹，避免同一 App 用户的多个
              // 学校 Profile 共享密文密钥和缓存文件。
              appUserId: '${profile.appUserId}/${profile.id}',
            );

  static const int _chunkBytes = 700;
  static const int _maxChunks = 256;
  static const int _manifestVersion = 2;
  static const String _prefix = 'local_school_profile/v1/';
  static const String _transactionMarker = 'transaction_in_progress';
  static const List<String> _fields = <String>[
    'student_id',
    'password',
    'cookie',
    'session_metadata',
  ];

  final LocalSchoolProfile profile;
  final AppSecretStore _secureStore;
  final AccountScopedSnapshotStore _snapshotStore;
  String? _ephemeralPassword;
  bool _closed = false;
  Future<void> _mutationTail = Future<void>.value();

  String get namespace =>
      '$_prefix${AccountCacheNamespace.fingerprint('${profile.appUserId}|${profile.id}')}/';

  AccountScopedSnapshotStore get snapshotStore => _snapshotStore;

  /// 内存中的本次登录密码；无论是否记住，关闭 Vault 时都会清除。
  String? get ephemeralPassword => _ephemeralPassword;

  Future<LocalSchoolCredentialSnapshot?> read() async {
    _ensureOpen();
    try {
      await _ensureCommittedSnapshot();
      final studentId = await _readValue('student_id');
      final password = await _readValue('password');
      final cookie = await _readValue('cookie');
      final metadataRaw = await _readValue('session_metadata');
      if (studentId == null || studentId.trim().isEmpty) return null;
      Map<String, dynamic> metadata = const <String, dynamic>{};
      if (metadataRaw != null && metadataRaw.isNotEmpty) {
        final decoded = jsonDecode(metadataRaw);
        if (decoded is! Map) {
          throw const LocalSchoolVaultException('学校会话元数据损坏');
        }
        metadata = Map<String, dynamic>.from(decoded);
      }
      return LocalSchoolCredentialSnapshot(
        studentId: studentId,
        password: password,
        cookie: cookie,
        sessionMetadata: metadata,
      );
    } on LocalSchoolVaultException {
      rethrow;
    } catch (_) {
      throw const LocalSchoolVaultException('学校凭据读取失败，已拒绝继续使用');
    }
  }

  Future<void> writeCredentials({
    required String studentId,
    String? password,
    String? cookie,
    Map<String, dynamic> sessionMetadata = const <String, dynamic>{},
    bool rememberPassword = false,
  }) {
    return _serializeMutation(() async {
      await _writeCredentialsUnlocked(
        studentId: studentId,
        password: password,
        cookie: cookie,
        sessionMetadata: sessionMetadata,
        rememberPassword: rememberPassword,
      );
    });
  }

  Future<void> _writeCredentialsUnlocked({
    required String studentId,
    String? password,
    String? cookie,
    required Map<String, dynamic> sessionMetadata,
    required bool rememberPassword,
  }) async {
    _ensureOpen();
    final normalizedStudentId = studentId.trim();
    if (normalizedStudentId.isEmpty) {
      throw const LocalSchoolVaultException('学校账号不能为空');
    }
    if (sessionMetadata.keys.any((key) => key.trim().isEmpty)) {
      throw const LocalSchoolVaultException('学校会话元数据字段无效');
    }
    try {
      await _beginMutation();
      _ephemeralPassword = password;
      await _writeValue('student_id', normalizedStudentId);
      if (cookie == null || cookie.trim().isEmpty) {
        await _deleteValue('cookie');
      } else {
        await _writeValue('cookie', cookie);
      }
      if (rememberPassword && password != null && password.isNotEmpty) {
        await _writeValue('password', password);
      } else {
        // 默认不保存密码；即使旧版本保存过，也在本次选择不记住时清掉。
        await _deleteValue('password');
      }
      final metadata = <String, dynamic>{
        ...sessionMetadata,
        'remember_password': rememberPassword,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _writeValue('session_metadata', jsonEncode(metadata));
      await _commitMutation();
    } catch (error) {
      _ephemeralPassword = null;
      if (error is LocalSchoolVaultException) rethrow;
      throw const LocalSchoolVaultException('学校凭据保存失败，已拒绝继续使用');
    }
  }

  /// 只更新 Cookie/会话元数据，不改变“是否记住密码”的选择。
  Future<void> writeSession({
    String? cookie,
    Map<String, dynamic> sessionMetadata = const <String, dynamic>{},
  }) async {
    final current = await read();
    await writeCredentials(
      studentId: current?.studentId ?? profile.studentId,
      password: _ephemeralPassword ?? current?.password,
      cookie: cookie,
      sessionMetadata: sessionMetadata,
      rememberPassword: current?.password != null,
    );
  }

  Future<void> clear() async {
    return _serializeMutation(_clearUnlocked);
  }

  Future<void> _clearUnlocked() async {
    if (_closed) return;
    await _beginMutation();
    Object? firstError;
    for (final field in _fields) {
      try {
        await _deleteValue(field);
      } catch (error) {
        firstError ??= error;
      }
    }
    _ephemeralPassword = null;
    if (firstError == null) {
      try {
        await _commitMutation();
      } catch (error) {
        firstError = error;
      }
    }
    if (firstError != null) {
      throw const LocalSchoolVaultException('学校凭据清理失败，已拒绝继续使用');
    }
  }

  /// 删除 Profile 时同时销毁其本地密文缓存密钥和文件。
  Future<void> deleteProfile() async {
    return _serializeMutation(() async {
      await _clearUnlocked();
      await _snapshotStore.clearUser();
      await _snapshotStore.close();
      _closed = true;
    });
  }

  /// 退出或切换账号时先清理内存，再关闭本 Profile 的 Vault。
  Future<void> close() async {
    return _serializeMutation(() async {
      _ephemeralPassword = null;
      if (_closed) return;
      await _snapshotStore.close();
      _closed = true;
    });
  }

  void _ensureOpen() {
    if (_closed) throw const LocalSchoolVaultException('学校 Profile Vault 已关闭');
  }

  String _key(String field, [int? index]) =>
      '$namespace$field${index == null ? '' : '.$index'}';

  String get _transactionKey => '$namespace$_transactionMarker';

  Future<void> _ensureCommittedSnapshot() async {
    final marker = await _secureStore.read(_transactionKey);
    if (marker != null && marker.isNotEmpty) {
      throw const LocalSchoolVaultException('学校凭据事务未完成，已拒绝继续使用');
    }
  }

  Future<void> _beginMutation() async {
    try {
      await _secureStore.write(
        _transactionKey,
        DateTime.now().toUtc().toIso8601String(),
      );
    } catch (_) {
      throw const LocalSchoolVaultException('学校凭据事务无法开始');
    }
  }

  Future<void> _commitMutation() async {
    try {
      await _secureStore.delete(_transactionKey);
    } catch (_) {
      throw const LocalSchoolVaultException('学校凭据事务无法提交');
    }
  }

  Future<T> _serializeMutation<T>(Future<T> Function() action) {
    final result = Completer<T>();
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    unawaited(() async {
      try {
        await previous;
      } catch (_) {
        // 前一操作的错误由其调用方接收；队列必须继续释放后续清理操作。
      }
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        release.complete();
      }
    }());
    return result.future;
  }

  Future<void> _writeValue(String field, String value) async {
    final bytes = utf8.encode(value);
    if (bytes.isEmpty) {
      await _deleteValue(field);
      return;
    }
    final count = (bytes.length / _chunkBytes).ceil();
    if (count > _maxChunks) {
      throw const LocalSchoolVaultException('学校秘密超过安全存储分块上限');
    }
    var oldCount = 0;
    try {
      final oldManifestRaw = await _secureStore.read(_key(field));
      if (oldManifestRaw != null && oldManifestRaw.isNotEmpty) {
        try {
          final oldManifest = _decodeManifest(oldManifestRaw);
          oldCount = oldManifest.chunks;
          if (oldManifest.version == 1) {
            final oldBytes = await _readChunks(field, oldManifest);
            await _secureStore.write(
              _key(field),
              _encodeManifest(oldBytes, oldManifest.chunks),
            );
          }
        } catch (_) {
          // 旧 manifest 或分块已损坏时，新登录可以覆盖，但成功后必须按
          // 上限清除无法确认计数的旧分块。
          oldCount = _maxChunks;
        }
      }

      // 先写完整分块，再提交带摘要的新 manifest。若中途失败，旧 manifest
      // 的摘要会使混合内容读取失败，不会把半写入凭据当成有效会话。
      for (var index = 0; index < count; index++) {
        final start = index * _chunkBytes;
        final end = (start + _chunkBytes).clamp(0, bytes.length);
        await _secureStore.write(
          _key(field, index),
          base64Encode(bytes.sublist(start, end)),
        );
      }
      await _secureStore.write(_key(field), _encodeManifest(bytes, count));
      for (var index = count; index < oldCount; index++) {
        await _secureStore.delete(_key(field, index));
      }
    } catch (_) {
      throw const LocalSchoolVaultException('学校秘密写入安全存储失败');
    }
  }

  Future<String?> _readValue(String field) async {
    final manifestRaw = await _secureStore.read(_key(field));
    if (manifestRaw == null || manifestRaw.isEmpty) return null;
    try {
      final manifest = _decodeManifest(manifestRaw);
      final bytes = await _readChunks(field, manifest);
      return utf8.decode(bytes);
    } on LocalSchoolVaultException {
      rethrow;
    } catch (_) {
      throw const LocalSchoolVaultException('学校秘密格式损坏，已拒绝继续使用');
    }
  }

  Future<void> _deleteValue(String field) async {
    final manifestKey = _key(field);
    Object? firstError;
    try {
      await _secureStore.delete(manifestKey);
    } catch (error) {
      firstError = error;
    }
    // manifest 可能在分块写入后提交失败，也可能本身已损坏；无法依赖其中
    // 的 count 做清理，因此按受控上限删除所有可能的残留块。
    for (var index = 0; index < _maxChunks; index++) {
      try {
        await _secureStore.delete(_key(field, index));
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw const LocalSchoolVaultException('学校秘密清理失败');
    }
  }

  String _encodeManifest(List<int> bytes, int chunks) {
    return jsonEncode(<String, dynamic>{
      'version': _manifestVersion,
      'chunks': chunks,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }

  _LocalSchoolSecretManifest _decodeManifest(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] is! int ||
        decoded['chunks'] is! int ||
        decoded['bytes'] is! int) {
      throw const FormatException();
    }
    final version = decoded['version'] as int;
    final chunks = decoded['chunks'] as int;
    final bytes = decoded['bytes'] as int;
    final digest = decoded['sha256'];
    if ((version != 1 && version != _manifestVersion) ||
        chunks <= 0 ||
        chunks > _maxChunks ||
        bytes < 1 ||
        (version == _manifestVersion &&
            (digest is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)))) {
      throw const FormatException();
    }
    return _LocalSchoolSecretManifest(
      version: version,
      chunks: chunks,
      bytes: bytes,
      digest: digest is String ? digest : null,
    );
  }

  Future<List<int>> _readChunks(
    String field,
    _LocalSchoolSecretManifest manifest,
  ) async {
    final bytes = <int>[];
    for (var index = 0; index < manifest.chunks; index++) {
      final encoded = await _secureStore.read(_key(field, index));
      if (encoded == null) throw const FormatException();
      bytes.addAll(base64Decode(encoded));
    }
    if (bytes.length != manifest.bytes) throw const FormatException();
    if (manifest.digest != null &&
        sha256.convert(bytes).toString() != manifest.digest) {
      throw const FormatException();
    }
    return bytes;
  }
}

class _LocalSchoolSecretManifest {
  const _LocalSchoolSecretManifest({
    required this.version,
    required this.chunks,
    required this.bytes,
    this.digest,
  });

  final int version;
  final int chunks;
  final int bytes;
  final String? digest;
}

/// 别名便于迁移代码表达“本地学校安全存储”语义。
typedef LocalSchoolSecureStorage = LocalSchoolCredentialVault;
