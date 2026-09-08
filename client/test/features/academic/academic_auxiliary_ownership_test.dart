import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_auxiliary_ownership.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
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
}
