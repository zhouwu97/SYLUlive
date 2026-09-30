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

  Future<void> update(void Function(Map<String, dynamic>) mutate) async {
    await _enqueueUpdate(mutate);
  }

  /// 在串行写队列真正执行时再次核对作用域。
  ///
  /// 页面上的检查只能挡住 await 返回后的提示，不能挡住已经排队的旧
  /// 操作；这里把检查放在读取和提交之间，失效操作不会写入新账号的记录。
  Future<bool> updateIfCurrent({
    required bool Function() current,
    required void Function(Map<String, dynamic>) mutate,
  }) =>
      _enqueueUpdate(mutate, current: current);

  Future<bool> _enqueueUpdate(
    void Function(Map<String, dynamic>) mutate, {
    bool Function()? current,
  }) {
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.then((_) async {
      if (current != null && !current()) return false;
      final state = read();
      if (current != null && !current()) return false;
      mutate(state);
      if (current != null && !current()) return false;
      if (!await preferences.setString(key, jsonEncode(state))) {
        throw StateError('保存本机教务账号失败');
      }
      return true;
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

  /// 核对完整云端列表后补入遗漏任务，不改变连接开关或凭据代次。
  Future<bool> ensureRegistrationQueued(
    AcademicIdentityKey identity, {
    required int expectedEpoch,
    required bool serverConfirmedAbsent,
    required bool Function() current,
  }) async {
    var queued = false;
    await update((state) {
      if (!current() || identity.appUserId != userId) return;
      final e = _entry(state, identity.providerId);
      final student = (e['student_id']?.toString() ?? '').trim();
      if (student.isEmpty ||
          student != identity.studentId ||
          (e['credential_epoch'] as int? ?? 0) != expectedEpoch ||
          e['enabled'] != true ||
          e['suppress_restore'] == true ||
          e['conflict'] == true ||
          e['remote_changed'] == true) {
        return;
      }

      final queue = e['outbox'] as List? ?? const <dynamic>[];
      if (queue.isNotEmpty) return;

      final snapshot = e['snapshot'] as Map?;
      // 曾经确认过的记录消失属于数据不一致，不能当作首次登记。
      if (serverConfirmedAbsent && snapshot != null) {
        e['remote_changed'] = true;
        e['server_missing'] = true;
        return;
      }
      if (!serverConfirmedAbsent || snapshot != null) return;

      _enqueue(e, student, false);
      queued = true;
    });
    return queued;
  }

  Future<void> commitIdentity(
    AcademicIdentityKey identity, {
    bool allowLegacyCleanup = false,
  }) =>
      update((state) {
        state['_active_provider'] = identity.providerId.value;
        final e = _entry(state, identity.providerId);
        final previousStudent = e['student_id']?.toString().trim();
        _queueCleanup(
          e,
          previousStudent,
          identity.studentId,
          allowLegacyCleanup: allowLegacyCleanup,
        );
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

  Future<void> remove(
    AcademicProviderId provider, {
    required bool fromCloud,
    bool allowLegacyCleanup = false,
  }) =>
      update((state) {
        final e = _entry(state, provider);
        final student = e['student_id']?.toString().trim();
        _queueCleanup(
          e,
          student,
          null,
          allowLegacyCleanup: allowLegacyCleanup,
        );
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

  /// 读取与 cleanup intent 一起持久化的旧版兼容数据认领许可。
  ///
  /// 只有采用配置时已经证明旧身份是当前身份，才会写入这个标记；恢复
  /// 时不能根据当前 controller 的身份重新猜测，否则切号后会扩大清理范围。
  bool cleanupIncludesLegacy(AcademicIdentityKey identity) {
    if (identity.appUserId != userId) return false;
    final legacy =
        entry(identity.providerId)['cleanup_legacy_students'] as List?;
    return legacy
            ?.any((student) => student?.toString() == identity.studentId) ??
        false;
  }

  Future<void> acknowledgeCleanup(AcademicIdentityKey identity) =>
      update((state) {
        if (identity.appUserId != userId) {
          throw ArgumentError(
            'Cannot acknowledge cleanup for identity ${identity.appUserId} in store of user $userId',
          );
        }
        final e = _entry(state, identity.providerId);
        (e['cleanup_students'] as List? ?? []).remove(identity.studentId);
        (e['cleanup_legacy_students'] as List? ?? [])
            .remove(identity.studentId);
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

  Future<void> mergeSnapshot(Map<String, dynamic> config,
          {bool Function()? current}) =>
      update((state) {
        if (current != null && !current()) return;
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
        e['server_missing'] = false;
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
          Map<String, dynamic> config,
          {bool Function()? current}) =>
      update((state) {
        if (current != null && !current()) return;
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

  Future<void> markConflict(AcademicProviderId provider,
          {bool Function()? current}) =>
      update((state) {
        if (current != null && !current()) return;
        _entry(state, provider)['conflict'] = true;
      });

  /// 另一设备已写入相同目标时可收敛；有后继操作的队列仍需显式处理版本。
  Future<void> resolveSatisfiedConflict(AcademicProviderId provider,
          {required bool Function() current}) =>
      update((state) {
        if (!current()) return;
        final e = _entry(state, provider);
        final queue = e['outbox'] as List? ?? [];
        final snapshot = e['snapshot'] as Map?;
        if (e['conflict'] != true || queue.length != 1 || snapshot == null) {
          return;
        }
        final op = queue.single as Map;
        final deleted = op['deleted'] == true;
        if ((snapshot['revision'] as int) <= (op['base_revision'] as int) ||
            snapshot['state'] != (deleted ? 'deleted' : 'active') ||
            (!deleted && snapshot['student_id'] != op['student_id'])) {
          return;
        }
        queue.clear();
        e['conflict'] = false;
        e['remote_changed'] = e['student_id'] != null &&
            (deleted || e['student_id'] != snapshot['student_id']);
      });

  AcademicConfigSyncStatus syncStatus(AcademicProviderId provider) {
    final e = entry(provider);
    if (e['conflict'] == true) return AcademicConfigSyncStatus.conflict;
    if (e['server_missing'] == true) {
      return AcademicConfigSyncStatus.serverMissing;
    }
    if (e['remote_changed'] == true) {
      return AcademicConfigSyncStatus.remoteChanged;
    }
    if ((e['outbox'] as List? ?? []).isNotEmpty) {
      return AcademicConfigSyncStatus.pending;
    }
    return e['snapshot'] == null
        ? AcademicConfigSyncStatus.unknown
        : AcademicConfigSyncStatus.synced;
  }

  Future<bool> keepLocal(
    AcademicProviderId provider, {
    bool Function()? current,
    String? expectedStudentId,
    bool requireExpectedStudent = false,
  }) {
    var mutated = false;
    void mutate(Map<String, dynamic> state) {
      final e = _entry(state, provider);
      if (requireExpectedStudent &&
          e['student_id']?.toString() != expectedStudentId) {
        return;
      }
      if (e['server_missing'] == true) {
        // 这是用户明确选择重建云端登记；缺失记录没有可复用的 revision。
        e['snapshot'] = null;
        e['server_missing'] = false;
      }
      e['outbox'] = <dynamic>[];
      e['conflict'] = false;
      e['remote_changed'] = false;
      _enqueue(e, e['student_id'] as String? ?? '', e['student_id'] == null);
      mutated = true;
    }

    final committed = current == null
        ? _enqueueUpdate(mutate)
        : updateIfCurrent(current: current, mutate: mutate);
    return committed.then((value) => value && mutated);
  }

  /// 采用云端投影，并在同一次账号记录写入中登记旧身份清理意图。
  /// 返回 false 表示作用域或操作前提已失效，调用方不能显示成功。
  Future<bool> adoptCloud(
    AcademicProviderId provider, {
    bool Function()? current,
    String? expectedStudentId,
    bool requireExpectedStudent = false,
    bool allowLegacyCleanup = false,
  }) {
    var mutated = false;
    void mutate(Map<String, dynamic> state) {
      final e = _entry(state, provider);
      if (requireExpectedStudent &&
          e['student_id']?.toString() != expectedStudentId) {
        return;
      }
      final previousStudent = e['student_id']?.toString().trim();
      if (e['server_missing'] == true) {
        // 云端没有可采用的目标，显式采用云端即解除本机对应身份。
        _queueCleanup(
          e,
          previousStudent,
          null,
          allowLegacyCleanup: allowLegacyCleanup,
        );
        e['student_id'] = null;
        e['enabled'] = false;
        e['snapshot'] = null;
        e['server_missing'] = false;
        e['outbox'] = <dynamic>[];
        e['remote_changed'] = false;
        e['suppress_restore'] = true;
        e['credential_epoch'] = (e['credential_epoch'] as int? ?? 0) + 1;
        e['rejected_epoch'] = null;
        mutated = true;
        return;
      }
      final cloud = e['snapshot'] as Map?;
      if (cloud == null) return;
      final nextStudent = cloud['state'] == 'active'
          ? cloud['student_id']?.toString().trim()
          : null;
      _queueCleanup(
        e,
        previousStudent,
        nextStudent,
        allowLegacyCleanup: allowLegacyCleanup,
      );
      e['student_id'] = nextStudent;
      e['enabled'] = true;
      e['suppress_restore'] = cloud['state'] != 'active';
      e['outbox'] = <dynamic>[];
      e['conflict'] = false;
      e['remote_changed'] = false;
      e['credential_epoch'] = (e['credential_epoch'] as int? ?? 0) + 1;
      e['rejected_epoch'] = null;
      mutated = true;
    }

    final committed = current == null
        ? _enqueueUpdate(mutate)
        : updateIfCurrent(current: current, mutate: mutate);
    return committed.then((value) => value && mutated);
  }

  static void _queueCleanup(
    Map<String, dynamic> entry,
    String? previousStudent,
    String? nextStudent, {
    bool allowLegacyCleanup = false,
  }) {
    final previous = previousStudent?.trim() ?? '';
    final next = nextStudent?.trim() ?? '';
    if (previous.isEmpty || previous == next) return;
    final cleanup =
        entry.putIfAbsent('cleanup_students', () => <dynamic>[]) as List;
    if (!cleanup.contains(previous)) cleanup.add(previous);
    if (allowLegacyCleanup) {
      final legacy = entry.putIfAbsent(
          'cleanup_legacy_students', () => <dynamic>[]) as List;
      if (!legacy.contains(previous)) legacy.add(previous);
    }
  }
}

/// 云端账号配置的事实状态，与服务端可信学生身份状态分开维护。
enum AcademicConfigSyncStatus {
  unknown,
  loading,
  synced,
  pending,
  conflict,
  remoteChanged,
  serverMissing,
  error,
}
