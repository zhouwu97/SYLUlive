import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  test('偏好 key 按 App 用户隔离', () async {
    final store = MemoryPreferencesStore();
    final first = AcademicStoragePreferences(appUserId: 'app-a', store: store);
    final second = AcademicStoragePreferences(appUserId: 'app-b', store: store);

    await first.setSaveCredentials(true);
    await first.setSaveAcademicData(false);

    expect(first.saveCredentials, isTrue);
    expect(first.saveAcademicData, isFalse);
    expect(second.saveCredentials, isFalse);
    expect(second.saveAcademicData, isTrue);
    expect(first.saveDataKey, isNot(second.saveDataKey));
  });

  test('新账号默认保存教务资料，但不默认保存密码，重载尊重显式关闭', () async {
    final store = MemoryPreferencesStore();
    final preferences =
        AcademicStoragePreferences(appUserId: 'app-a', store: store);
    expect(preferences.saveAcademicData, isTrue);
    expect(preferences.saveCredentials, isFalse);
    await preferences.setSaveAcademicData(false);
    final reloaded =
        AcademicStoragePreferences(appUserId: 'app-a', store: store);
    expect(reloaded.saveAcademicData, isFalse);
    expect(
        AcademicStoragePreferences(appUserId: '', store: store)
            .saveAcademicData,
        isFalse);
  });

  test('清理 pending 状态可被可靠记录', () async {
    final store = MemoryPreferencesStore();
    final preferences =
        AcademicStoragePreferences(appUserId: 'app-a', store: store);
    await preferences.setCleanupPending(true);
    expect(preferences.cleanupPending, isTrue);
    await preferences.setCleanupPending(false);
    expect(preferences.cleanupPending, isFalse);
  });
}
