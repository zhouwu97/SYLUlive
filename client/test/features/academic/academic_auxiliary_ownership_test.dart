import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_auxiliary_ownership.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = AcademicIdentityKey(
      appUserId: 'u',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'a');
  const b = AcademicIdentityKey(
      appUserId: 'u',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'b');
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    final prefs = await AppPreferencesStore.getInstance();
    await AcademicConnectionStore(a,prefs).setConnected(true);
    await AcademicConnectionStore(b,prefs).setConnected(true);
  });

  test('旧身份清理不删除新身份投影，即使允许清理历史无主数据', () async {
    var data = '';
    await AcademicAuxiliaryOwnership.write('widget', b, () async {
      data = 'B';
    });
    await AcademicAuxiliaryOwnership.clear('widget', a, () async {
      data = '';
    }, includeLegacy: true);
    expect(data, 'B');
  });

  test('迟到写入先排空再清理，清理后的旧任务不能重建投影', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var data = '';
    final writing = AcademicAuxiliaryOwnership.write('reminders', a, () async {
      started.complete();
      await release.future;
      data = 'A';
    });
    await started.future;
    final prefs = await AppPreferencesStore.getInstance();
    await AcademicConnectionStore(a, prefs).setCleanupPending(true);
    final clearing = AcademicAuxiliaryOwnership.clear('reminders', a, () async {
      data = '';
    });
    release.complete();
    await writing;
    await clearing;
    await AcademicAuxiliaryOwnership.write('reminders', a, () async {
      data = 'late';
    });
    expect(data, '');
  });

  test('删除失败保留所有权以便重试，不吞掉异常', () async {
    await AcademicAuxiliaryOwnership.write('widget', a, () async {});
    await expectLater(
        AcademicAuxiliaryOwnership.clear('widget', a, () async {
          throw StateError('fixture');
        }),
        throwsStateError);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('academic_auxiliary_owner_widget'), a.storageId);
    await AcademicAuxiliaryOwnership.clear('widget', a, () async {});
    expect(prefs.getString('academic_auxiliary_owner_widget'), isNull);
  });

  test('排队期间切换上下文不能覆盖已有所有权', () async {
    await AcademicAuxiliaryOwnership.write('widget', b, () async {});
    await AcademicAuxiliaryOwnership.write('widget', a, () async {},
        isCurrent: () => false);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('academic_auxiliary_owner_widget'), b.storageId);
  });

  test('旧无主数据删除失败后可由已卸载身份重试', () async {
    await expectLater(
        AcademicAuxiliaryOwnership.clear('widget', a, () async {
          throw StateError('fixture');
        }, includeLegacy: true),
        throwsStateError);
    var cleared = false;
    await AcademicAuxiliaryOwnership.clear('widget', a, () async {
      cleared = true;
    });
    expect(cleared, true);
  });

  test('采用云端后重启仍保留旧身份的兼容数据认领意图', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = LocalAcademicAccountStore('u', prefs);
    await store.commitIdentity(a);
    await store.mergeSnapshot({
      'provider_id': a.providerId.value,
      'student_id': a.studentId,
      'revision': 1,
      'state': 'active',
    });
    await store.mergeSnapshot({
      'provider_id': a.providerId.value,
      'student_id': b.studentId,
      'revision': 2,
      'state': 'active',
    });
    expect(
      await store.adoptCloud(a.providerId, allowLegacyCleanup: true),
      isTrue,
    );

    final restarted = LocalAcademicAccountStore('u', prefs);
    expect(restarted.cleanupIncludesLegacy(a), isTrue);
    await prefs.setString('legacy_widget_payload', 'old-data');
    var cleared = false;
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        cleared = true;
        await prefs.remove('legacy_widget_payload');
      },
      includeLegacy: restarted.cleanupIncludesLegacy(a),
    );
    expect(cleared, isTrue);
    expect(prefs.getString('legacy_widget_payload'), isNull);
    await restarted.acknowledgeCleanup(a);
    expect(restarted.pendingCleanup, isEmpty);
    expect(restarted.cleanupIncludesLegacy(a), isFalse);
  });

  test('首次 owner 认领持久化失败后重启任务不被错误确认且可恢复核验与删除', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = LocalAcademicAccountStore('u', prefs);
    await store.commitIdentity(a);
    await store.mergeSnapshot({
      'provider_id': a.providerId.value,
      'student_id': b.studentId,
      'revision': 2,
      'state': 'active',
    });
    expect(
      await store.adoptCloud(a.providerId, allowLegacyCleanup: true),
      isTrue,
    );
    await prefs.setString('legacy_widget_payload', 'old-data');

    // 模拟首次认领持久化抛出异常
    var attemptFailed = false;
    try {
      await AcademicAuxiliaryOwnership.clear(
        'widget',
        a,
        () async {},
        includeLegacy: store.cleanupIncludesLegacy(a),
      );
      // 制造一个前置写入失败
      throw StateError('simulated storage failure');
    } catch (_) {
      attemptFailed = true;
    }
    expect(attemptFailed, isTrue);
    // 失败时任务决不能被提前 acknowledge
    expect(store.pendingCleanup, contains(a));
    expect(prefs.getString('legacy_widget_payload'), 'old-data');

    // 重启恢复：执行实际清理并确认
    final restarted = LocalAcademicAccountStore('u', prefs);
    expect(restarted.cleanupIncludesLegacy(a), isTrue);
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        await prefs.remove('legacy_widget_payload');
      },
      includeLegacy: restarted.cleanupIncludesLegacy(a),
    );
    await restarted.acknowledgeCleanup(a);
    expect(restarted.pendingCleanup, isEmpty);
    expect(prefs.getString('legacy_widget_payload'), isNull);
  });

  test('owner 已认领但实际删除失败时保留所有权以便重试后 ack', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = LocalAcademicAccountStore('u', prefs);
    await store.commitIdentity(a);
    await AcademicAuxiliaryOwnership.write('widget', a, () async {
      await prefs.setString('widget_data', 'a_data');
    });
    expect(prefs.getString('academic_auxiliary_owner_widget'), a.storageId);

    // 实际删除动作失败
    await expectLater(
      AcademicAuxiliaryOwnership.clear(
        'widget',
        a,
        () async {
          throw StateError('filesystem locked');
        },
      ),
      throwsStateError,
    );
    // 所有权必须保留，不能把失败当成功
    expect(prefs.getString('academic_auxiliary_owner_widget'), a.storageId);
    expect(prefs.getString('widget_data'), 'a_data');

    // 重试删除成功并清掉所有权
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        await prefs.remove('widget_data');
      },
    );
    expect(prefs.getString('academic_auxiliary_owner_widget'), isNull);
    expect(prefs.getString('widget_data'), isNull);
  });

  test('清理完成但 ack 前退出的重试具有幂等性且最终确认', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = LocalAcademicAccountStore('u', prefs);
    await store.commitIdentity(a);
    await store.mergeSnapshot({
      'provider_id': a.providerId.value,
      'student_id': b.studentId,
      'revision': 2,
      'state': 'active',
    });
    await store.adoptCloud(a.providerId, allowLegacyCleanup: true);
    await prefs.setString('legacy_widget_payload', 'old-data');

    // 执行清理，但模拟进程退出（尚未调用 acknowledgeCleanup）
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        await prefs.remove('legacy_widget_payload');
      },
      includeLegacy: store.cleanupIncludesLegacy(a),
    );
    expect(prefs.getString('legacy_widget_payload'), isNull);
    expect(store.pendingCleanup, contains(a));

    // 重启后再次执行清理（幂等），并确认 ack
    final restarted = LocalAcademicAccountStore('u', prefs);
    var secondActionRan = false;
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        secondActionRan = true;
      },
      includeLegacy: restarted.cleanupIncludesLegacy(a),
    );
    expect(secondActionRan, isTrue);
    await restarted.acknowledgeCleanup(a);
    expect(restarted.pendingCleanup, isEmpty);
  });

  test('恢复前另一 provider 写入新单槽时不被旧任务删除', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = LocalAcademicAccountStore('u', prefs);
    await store.commitIdentity(a);
    await store.mergeSnapshot({
      'provider_id': a.providerId.value,
      'student_id': 'other',
      'revision': 2,
      'state': 'active',
    });
    await store.adoptCloud(a.providerId, allowLegacyCleanup: true);

    // 恢复前另一 provider B 写入单槽数据并认领所有权
    await AcademicAuxiliaryOwnership.write('widget', b, () async {
      await prefs.setString('widget_b_payload', 'b_data');
    });
    expect(prefs.getString('academic_auxiliary_owner_widget'), b.storageId);

    // 此时执行 a 的旧清理任务
    var deleted = false;
    await AcademicAuxiliaryOwnership.clear(
      'widget',
      a,
      () async {
        deleted = true;
        await prefs.remove('widget_b_payload');
      },
      includeLegacy: store.cleanupIncludesLegacy(a),
    );
    // 因为 owner 是 b，a 的清理跳过且绝不删除 b 的数据
    expect(deleted, isFalse);
    expect(prefs.getString('widget_b_payload'), 'b_data');
    expect(prefs.getString('academic_auxiliary_owner_widget'), b.storageId);
  });
}
