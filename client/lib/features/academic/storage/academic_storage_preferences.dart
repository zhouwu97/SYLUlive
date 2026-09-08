import 'dart:convert';
import '../domain/academic_provider.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../platform/contracts/preferences_store.dart';

/// 教务本机保存偏好的账号隔离封装。
final class AcademicStoragePreferences {
  AcademicStoragePreferences({
    required this.appUserId,
    required this.store,
    this.identity,
  });

  final AcademicIdentityKey? identity;
  final String appUserId;
  final AppPreferencesStore store;

  String? get _hash {
    if (identity != null) return identity!.storageId;
    final value = appUserId.trim();
    if (value.isEmpty) return null;
    return sha256.convert(utf8.encode(value)).toString();
  }

  String? get saveCredentialsKey => appUserId.trim().isEmpty
      ? null
      : identity == null
          ? 'academic_save_credentials_$_hash'
          : 'academic_save_credentials_provider_${sha256.convert(utf8.encode('$appUserId|${identity!.providerId.value}'))}';

  String? get saveDataKey => _hash == null ? null : 'academic_save_data_$_hash';

  String? get migrationKey =>
      _hash == null ? null : 'academic_storage_migration_v1_$_hash';

  String? get cleanupPendingKey =>
      _hash == null ? null : 'academic_cache_cleanup_pending_$_hash';

  bool get saveCredentials =>
      !kIsWeb &&
      saveCredentialsKey != null &&
      (store.getBool(saveCredentialsKey!) ??
          store.getBool('academic_save_credentials_$_hash') ??
          true);

  // 沿用当前分支自动保存课表、成绩和自定义课表的行为；显式关闭仍优先。
  bool get saveAcademicData =>
      !kIsWeb && saveDataKey != null && (store.getBool(saveDataKey!) ?? true);

  bool get cleanupPending =>
      cleanupPendingKey != null && store.getBool(cleanupPendingKey!) == true;

  /// 将旧账号级选择复制到当前已确认身份；标记保留，完整清理后不得再次导入旧许可。
  Future<void> migrateLegacyPreferences() async {
    final current = identity;
    if (current == null) return;
    final marker =
        'academic_identity_preferences_migrated_v4_${current.storageId}';
    if (store.getBool(marker) == true) return;
    final legacy =
        AcademicStoragePreferences(appUserId: appUserId, store: store);
    if (!store.containsKey(saveCredentialsKey!)) {
      final previous =
          store.getBool('academic_save_credentials_${current.storageId}');
      final explicitChoice =
          previous ?? store.getBool(legacy.saveCredentialsKey!);
      // 默认值不落成用户选择，避免预填界面先写 true 后遮蔽旧身份的显式关闭。
      if (explicitChoice != null) await setSaveCredentials(explicitChoice);
    }
    if (!store.containsKey(saveDataKey!)) {
      await setSaveAcademicData(legacy.saveAcademicData);
    }
    if (!await store.setBool(marker, true)) throw StateError('迁移教务身份偏好失败');
  }

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
      saveDataKey,
      migrationKey,
      cleanupPendingKey,
    ];
    for (final key in keys.whereType<String>()) {
      if (!await store.remove(key)) throw StateError('清理教务偏好失败');
    }
  }
}
