import 'local_academic_account_store.dart';
import 'dart:convert';
import '../../../platform/contracts/preferences_store.dart';
import '../domain/academic_provider.dart';

/// 连接许可和清理日志始终按完整身份保存；读取失败由调用方阻断联网。
final class AcademicConnectionStore {
  AcademicConnectionStore(this.identity, this.preferences);

  final AcademicIdentityKey identity;
  final AppPreferencesStore preferences;
  String get _prefix => 'academic_lifecycle_${identity.storageId}';
  String get bindingSyncState =>
      preferences.getString('${_prefix}_binding_sync') ?? 'none';

  Future<void> setBindingSyncState(String state) async {
    if (!await preferences.setString('${_prefix}_binding_sync', state)) {
      throw StateError('保存学生身份同步状态失败');
    }
  }

  bool get cleanupPending => preferences.getBool('${_prefix}_cleanup') == true;
  Map<String, dynamic> get _local =>
      LocalAcademicAccountStore(identity.appUserId, preferences)
          .entry(identity.providerId);
  bool get connected {
    if (cleanupPending) return false;
    final local = _local;
    if (local['student_id'] == identity.studentId) {
      return local['enabled'] == true;
    }
    return preferences.getBool('${_prefix}_connected') == true;
  }

  bool get initialized =>
      _local['student_id'] == identity.studentId ||
      preferences.getBool('${_prefix}_connected') != null;

  Future<void> setConnected(bool value) async {
    if (!value) await setBindingSyncState('none');
    if (_local['student_id'] == identity.studentId) {
      await LocalAcademicAccountStore(identity.appUserId, preferences)
          .setEnabled(identity.providerId, value);
      return;
    }
    if (!identity.isValid ||
        !await preferences.setBool('${_prefix}_connected', value)) {
      throw StateError('保存本机教务连接状态失败');
    }
  }

  static List<AcademicIdentityKey> pendingIdentities(
      AppPreferencesStore preferences, String appUserId) {
    final result = <AcademicIdentityKey>[];
    for (final key in preferences.getKeys().where((key) =>
        key.startsWith('academic_lifecycle_') && key.endsWith('_identity'))) {
      Object? decoded;
      try {
        decoded = jsonDecode(preferences.getString(key) ?? '{}');
      } on FormatException {
        // 单条损坏日志不能阻止其他身份完成清理；原记录保留供排查。
        continue;
      }
      if (decoded is! Map) continue;
      final data = decoded;
      final provider =
          AcademicProviderId.tryParse(data['provider']?.toString() ?? '');
      if (provider == null || data['user'] != appUserId) continue;
      final identity = AcademicIdentityKey(
          appUserId: appUserId,
          providerId: provider,
          studentId: data['student'].toString());
      if (identity.isValid &&
          key == 'academic_lifecycle_${identity.storageId}_identity' &&
          AcademicConnectionStore(identity, preferences).cleanupPending) {
        result.add(identity);
      }
    }
    return result;
  }

  Future<void> setCleanupPending(bool value) async {
    if (value) await setBindingSyncState('none');
    if (value &&
        !await preferences.setString(
            '${_prefix}_identity',
            jsonEncode({
              'user': identity.appUserId,
              'provider': identity.providerId.value,
              'student': identity.studentId,
            }))) {
      throw StateError('保存待清理身份失败');
    }
    if (!await preferences.setBool('${_prefix}_cleanup', value)) {
      throw StateError('保存教务身份清理状态失败');
    }
  }
}
