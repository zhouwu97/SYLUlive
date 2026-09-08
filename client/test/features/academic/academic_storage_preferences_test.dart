import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
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
    expect(second.saveCredentials, isTrue);
    expect(second.saveAcademicData, isTrue);
    expect(first.saveDataKey, isNot(second.saveDataKey));
  });

  test('新账号默认保存教务资料和密码，重载尊重显式关闭', () async {
    final store = MemoryPreferencesStore();
    final preferences =
        AcademicStoragePreferences(appUserId: 'app-a', store: store);
    expect(preferences.saveAcademicData, isTrue);
    expect(preferences.saveCredentials, isTrue);
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
  test('身份偏好迁移保留旧许可，清除后不会再次导入', () async {
    final store = MemoryPreferencesStore();
    final legacy = AcademicStoragePreferences(appUserId: 'u', store: store);
    await legacy.setSaveCredentials(true);
    await legacy.setSaveAcademicData(false);
    final scoped = AcademicStoragePreferences(
        appUserId: 'u',
        store: store,
        identity: const AcademicIdentityKey(
            appUserId: 'u',
            providerId: AcademicProviderId.syluUndergraduate,
            studentId: 'a'));
    await scoped.migrateLegacyPreferences();
    expect(scoped.saveCredentials, true);
    expect(scoped.saveAcademicData, false);
    await scoped.clear();
    await scoped.migrateLegacyPreferences();
    expect(scoped.saveCredentials, true);
  });

  test('同一 Provider 换学号继承显式关闭，另一 Provider 不受影响', () async {
    final store = MemoryPreferencesStore();
    AcademicStoragePreferences settings(
            String student, AcademicProviderId provider) =>
        AcademicStoragePreferences(
            appUserId: 'u',
            store: store,
            identity: AcademicIdentityKey(
                appUserId: 'u', providerId: provider, studentId: student));
    final a = settings('A', AcademicProviderId.syluUndergraduate);
    await a.setSaveCredentials(false);
    final b = settings('B', AcademicProviderId.syluUndergraduate);
    await b.migrateLegacyPreferences();
    expect(b.saveCredentials, false);
    expect(
        settings('B', AcademicProviderId.syluGraduate).saveCredentials, true);
    await a.clear();
    expect(b.saveCredentials, false);
  });

  test('首次预填的默认值不遮蔽旧身份明确关闭密码保存', () async {
    final store = MemoryPreferencesStore();
    const old = AcademicIdentityKey(
        appUserId: 'u',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G');
    await store.setBool('academic_save_credentials_${old.storageId}', false);
    final preview = AcademicStoragePreferences(
        appUserId: 'u',
        store: store,
        identity: const AcademicIdentityKey(
            appUserId: 'u',
            providerId: AcademicProviderId.syluGraduate,
            studentId: '_preference'));
    await preview.migrateLegacyPreferences();
    final actual =
        AcademicStoragePreferences(appUserId: 'u', store: store, identity: old);
    await actual.migrateLegacyPreferences();
    expect(actual.saveCredentials, false);
    expect(preview.saveCredentials, false);
  });
}
