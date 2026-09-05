import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../platform/contracts/preferences_store.dart';

/// 教务本机保存偏好的账号隔离封装。
final class AcademicStoragePreferences {
  AcademicStoragePreferences({
    required this.appUserId,
    required this.store,
  });

  final String appUserId;
  final AppPreferencesStore store;

  String? get _hash {
    final value = appUserId.trim();
    if (value.isEmpty) return null;
    return sha256.convert(utf8.encode(value)).toString();
  }

  String? get saveCredentialsKey =>
      _hash == null ? null : 'academic_save_credentials_$_hash';

  String? get saveDataKey => _hash == null ? null : 'academic_save_data_$_hash';

  String? get migrationKey =>
      _hash == null ? null : 'academic_storage_migration_v1_$_hash';

  String? get cleanupPendingKey =>
      _hash == null ? null : 'academic_cache_cleanup_pending_$_hash';

  bool get saveCredentials =>
      saveCredentialsKey != null && store.getBool(saveCredentialsKey!) == true;

  bool get saveAcademicData =>
      saveDataKey != null && store.getBool(saveDataKey!) == true;

  bool get cleanupPending =>
      cleanupPendingKey != null && store.getBool(cleanupPendingKey!) == true;

  Future<void> setSaveCredentials(bool enabled) async {
    final key = saveCredentialsKey;
    if (key == null || !await store.setBool(key, enabled)) {
      throw StateError('保存教务凭据偏好失败');
    }
  }

  Future<void> setSaveAcademicData(bool enabled) async {
    final key = saveDataKey;
    if (key == null || !await store.setBool(key, enabled)) {
      throw StateError('保存教务资料偏好失败');
    }
  }

  Future<void> setCleanupPending(bool pending) async {
    final key = cleanupPendingKey;
    if (key == null) return;
    if (pending) {
      if (!await store.setBool(key, true)) {
        throw StateError('记录教务资料清理状态失败');
      }
    } else if (!await store.remove(key)) {
      throw StateError('清除教务资料清理状态失败');
    }
  }

  Future<void> markMigrated() async {
    final key = migrationKey;
    if (key == null || !await store.setBool(key, true)) {
      throw StateError('记录教务资料迁移状态失败');
    }
  }

  bool get hasMigrated =>
      migrationKey != null && store.getBool(migrationKey!) == true;

  Future<void> clear() async {
    final keys = <String?>[
      saveCredentialsKey,
      saveDataKey,
      migrationKey,
      cleanupPendingKey,
    ];
    for (final key in keys.whereType<String>()) {
      if (!await store.remove(key)) throw StateError('清理教务偏好失败');
    }
  }
}
