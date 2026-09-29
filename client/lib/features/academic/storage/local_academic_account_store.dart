import 'dart:async';
import 'dart:convert';
import '../../../services/idempotency_key.dart';
import '../../../platform/contracts/preferences_store.dart';
import '../domain/academic_provider.dart';

/// 每个 App 用户一个完整记录；账号、快照和待同步操作以一次原子值写入提交。
/// 同进程写入串行化，避免同步响应与本机换绑互相覆盖。
final class LocalAcademicAccountStore {
  LocalAcademicAccountStore(this.userId, this.preferences);
  final String userId;
  final AppPreferencesStore preferences;
  static final Map<String, Future<void>> _tails = {};
  String get key => 'academic_accounts_v4_$userId';

  Map<String, dynamic> read() {
    final raw = preferences.getString(key);
    if (raw == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> update(void Function(Map<String, dynamic>) mutate) {
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.then((_) async {
      final state = read();
      mutate(state);
      if (!await preferences.setString(key, jsonEncode(state))) {
        throw StateError('保存本机教务账号失败');
      }
    });
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tails[key] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }));
    return next;
  }

  List<AcademicIdentityKey> get identities => read()
      .entries
      .where((e) =>
          AcademicProviderId.tryParse(e.key) != null &&
          e.value['student_id'] != null)
      .map((e) => AcademicIdentityKey(
          appUserId: userId,
          providerId: AcademicProviderId.tryParse(e.key)!,
          studentId: e.value['student_id'] as String))
      .toList();

  Map<String, dynamic> entry(AcademicProviderId provider) =>
      Map<String, dynamic>.from(read()[provider.value] as Map? ?? {});

  Future<void> importLegacy(AcademicIdentityKey identity,
          {required bool enabled}) =>
      update((state) {
        final e = _entry(state, identity.providerId);
        if (e['student_id'] != null) return;
        e['student_id'] = identity.studentId;
        e['enabled'] = enabled;
      });

  Future<void> commitIdentity(AcademicIdentityKey identity) => update((state) {
        state['_active_provider'] = identity.providerId.value;
        final e = _entry(state, identity.providerId);
        final previousStudent = e['student_id'];
        if (previousStudent != null && previousStudent != identity.studentId) {
          final cleanup =
              e.putIfAbsent('cleanup_students', () => <dynamic>[]) as List;
          if (!cleanup.contains(previousStudent)) cleanup.add(previousStudent);
        }
        e['student_id'] = identity.studentId;
        e['enabled'] = true;
        e['rejected_epoch'] = null;
        e['credential_epoch'] = (e['credential_epoch'] as int? ?? 0) + 1;
        e['suppress_restore'] = false;
        final snapshot = e['snapshot'] as Map?;
        if (previousStudent != identity.studentId ||
            (e['outbox'] as List? ?? []).isEmpty &&
                snapshot != null &&
                (snapshot['state'] != 'active' ||
                    snapshot['student_id'] != identity.studentId)) {
          _enqueue(e, identity.studentId, false);
        }
      });

  Future<void> remove(AcademicProviderId provider, {required bool fromCloud}) =>
      update((state) {
        final e = _entry(state, provider);
        final student = e['student_id'];
        if (student != null) {
          final cleanup =
              e.putIfAbsent('cleanup_students', () => <dynamic>[]) as List;
          if (!cleanup.contains(student)) cleanup.add(student);
        }
        e['student_id'] = null;
        e['enabled'] = false;
        e['credential_epoch'] = (e['credential_epoch'] as int? ?? 0) + 1;
        e['suppress_restore'] = fromCloud;
        if (fromCloud) _enqueue(e, '', true);
      });

  List<AcademicIdentityKey> get pendingCleanup => read()
      .entries
      .where((e) => AcademicProviderId.tryParse(e.key) != null)
      .expand((e) => (e.value['cleanup_students'] as List? ?? []).map(
          (student) => AcademicIdentityKey(
              appUserId: userId,
              providerId: AcademicProviderId.tryParse(e.key)!,
              studentId: student as String)))
      .toList();

  Future<void> acknowledgeCleanup(AcademicIdentityKey identity) =>
      update((state) {
        final e = _entry(state, identity.providerId);
        (e['cleanup_students'] as List? ?? []).remove(identity.studentId);
      });

  AcademicProviderId? get activeProvider =>
      AcademicProviderId.tryParse(read()['_active_provider'] as String? ?? '');
  Future<void> setActive(AcademicProviderId provider) => update((state) {
        state['_active_provider'] = provider.value;
      });

  Future<void> setEnabled(AcademicProviderId provider, bool enabled) =>
      update((state) {
        _entry(state, provider)['enabled'] = enabled;
      });

  int epoch(AcademicProviderId provider) =>
      entry(provider)['credential_epoch'] as int? ?? 0;
  bool rejected(AcademicProviderId provider) {
    final e = entry(provider);
    return e['rejected_epoch'] != null &&
        e['rejected_epoch'] == (e['credential_epoch'] ?? 0);
  }

  Future<void> reject(AcademicProviderId provider, int epoch) =>
      update((state) {
        final e = _entry(state, provider);
        if ((e['credential_epoch'] ?? 0) == epoch) e['rejected_epoch'] = epoch;
      });

  static Map<String, dynamic> _entry(
          Map<String, dynamic> state, AcademicProviderId provider) =>
      state.putIfAbsent(provider.value, () => <String, dynamic>{})
          as Map<String, dynamic>;

  static void _enqueue(Map<String, dynamic> e, String student, bool deleted) {
    final queue = e.putIfAbsent('outbox', () => <dynamic>[]) as List;
    // 已发出的操作不可改写；后继操作使用前驱成功后必然获得的版本。
    final base = queue.isEmpty
        ? ((e['snapshot'] as Map?)?['revision'] as int? ?? 0)
        : (queue.last['base_revision'] as int) + 1;
    queue.add({
      'operation_id': newIdempotencyKey('academic'),
      'student_id': student,
      'deleted': deleted,
      'base_revision': base
    });
  }

  Future<void> mergeSnapshot(Map<String, dynamic> config) => update((state) {
        final provider =
            AcademicProviderId.tryParse(config['provider_id'] as String? ?? '');
        if (provider == null) return;
        final e = _entry(state, provider);
        final previous = e['snapshot'] as Map?;
        if ((config['revision'] as int) <
            (previous?['revision'] as int? ?? 0)) {
          return;
        }
        e['snapshot'] = config;
        final pending = (e['outbox'] as List? ?? []).isNotEmpty;
        if (e['student_id'] == null &&
            !pending &&
            e['suppress_restore'] != true &&
            config['state'] == 'active') {
          e['student_id'] = config['student_id'];
          e['enabled'] = true;
        }
        e['remote_changed'] = !pending &&
            e['student_id'] != null &&
            (config['state'] != 'active' ||
                e['student_id'] != config['student_id']);
      });

  Future<void> acknowledge(AcademicProviderId provider, String operation,
          Map<String, dynamic> config) =>
      update((state) {
        final e = _entry(state, provider);
        final queue = e['outbox'] as List? ?? [];
        if (queue.isEmpty || queue.first['operation_id'] != operation) return;
        queue.removeAt(0);
        final previous = e['snapshot'] as Map?;
        if ((config['revision'] as int) >=
            (previous?['revision'] as int? ?? 0)) {
          e['snapshot'] = config;
        }
        e['conflict'] = false;
        // 保留删除抑制标记，迟到的 GET 即使越过当前请求也不能复活本机配置。
      });

  Future<void> markConflict(AcademicProviderId provider) => update((state) {
        _entry(state, provider)['conflict'] = true;
      });

  Future<void> keepLocal(AcademicProviderId provider) => update((state) {
        final e = _entry(state, provider);
        e['outbox'] = <dynamic>[];
        e['conflict'] = false;
        e['remote_changed'] = false;
        _enqueue(e, e['student_id'] as String? ?? '', e['student_id'] == null);
      });

  Future<void> adoptCloud(AcademicProviderId provider) => update((state) {
        final e = _entry(state, provider);
        final cloud = e['snapshot'] as Map?;
        if (cloud == null) return;
        e['student_id'] =
            cloud['state'] == 'active' ? cloud['student_id'] : null;
        e['enabled'] = true;
        e['suppress_restore'] = cloud['state'] != 'active';
        e['outbox'] = <dynamic>[];
        e['conflict'] = false;
        e['remote_changed'] = false;
        e['credential_epoch'] = (e['credential_epoch'] as int? ?? 0) + 1;
        e['rejected_epoch'] = null;
      });
}
