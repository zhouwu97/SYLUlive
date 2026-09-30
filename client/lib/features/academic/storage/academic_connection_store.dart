import 'local_academic_account_store.dart';
import 'dart:convert';
import '../../../platform/contracts/preferences_store.dart';
import '../domain/academic_provider.dart';

/// 本机声明（/student-identity/bind）的投递状态。
///
/// 「本机已连接」（connected）、「账号配置已同步」（配置 outbox）、「身份已核验」
/// （服务端可信绑定）是三件不同的事，这里只描述**声明**投递到哪一步，
/// 不能拿它当学生认证结论用。
abstract final class AcademicBindingSyncState {
  /// 尚未投递。
  static const none = 'none';

  /// 待投递：允许在联网恢复、应用重启后补发。
  static const pending = 'pending';

  /// 服务端已接收声明。它**不构成**服务器可信学生认证。
  static const declared = 'declared';

  /// 服务端拒绝或回执不符合契约。不再自动重试——契约错误重试不会变好，
  /// 只会让用户每隔几十秒被提醒一次。重新连接教务会把状态归零并允许再试。
  static const rejected = 'rejected';

  /// 历史版本在「声明已接收」时写下的终态，语义等同 [declared]。
  static const legacyBound = 'bound';
}

/// 连接许可和清理日志始终按完整身份保存；读取失败由调用方阻断联网。
final class AcademicConnectionStore {
  AcademicConnectionStore(this.identity, this.preferences);

  final AcademicIdentityKey identity;
  final AppPreferencesStore preferences;
  String get _prefix => 'academic_lifecycle_${identity.storageId}';
  String get bindingSyncState =>
      preferences.getString('${_prefix}_binding_sync') ?? AcademicBindingSyncState.none;

  /// 声明是否已经投递过（含历史版本的 bound 终态）。
  bool get bindingDeclared {
    final state = bindingSyncState;
    return state == AcademicBindingSyncState.declared ||
        state == AcademicBindingSyncState.legacyBound;
  }

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
