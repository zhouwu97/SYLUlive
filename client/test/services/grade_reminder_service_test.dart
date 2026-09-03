import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/platform/contracts/reminder_notification_client.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/services/grade_reminder_service.dart';

void main() {
  test('首次启用只建立加密基线，不发送通知', () async {
    final source = _FakeAcademicDataSource(_rawGrade('88'));
    final controller = await _loggedInController(source);
    final vault = _MemorySnapshotStore();
    final notifications = _FakeReminderNotificationClient();
    final service = _service(controller, vault, notifications);

    await service.setEnabled(
      enabled: true,
      userId: 'app-a',
      year: '2026',
      semester: 3,
      grades: [_grade('88')],
    );
    await service.runCheckNow();

    expect(notifications.gradeUpdates, isEmpty);
    controller.dispose();
  });

  test('成绩变化发送本地通知且不依赖共享 App API', () async {
    final source = _FakeAcademicDataSource(_rawGrade('88'));
    final controller = await _loggedInController(source);
    final vault = _MemorySnapshotStore();
    final notifications = _FakeReminderNotificationClient();
    final service = _service(controller, vault, notifications);

    await service.setEnabled(
      enabled: true,
      userId: 'app-a',
      year: '2026',
      semester: 3,
      grades: [_grade('88')],
    );
    source.rawGrade = _rawGrade('92');
    await service.runCheckNow();

    expect(notifications.gradeUpdates, hasLength(1));
    expect(notifications.gradeUpdates.single.body, contains('88 -> 92'));
    expect(source.gradeCalls, 1);
    controller.dispose();
  });

  test('账号或学号变化不会读取另一份成绩基线', () async {
    final source = _FakeAcademicDataSource(_rawGrade('88'));
    final controller = await _loggedInController(source, appUserId: 'app-a');
    final vaults = <String, _MemorySnapshotStore>{};
    final notifications = _FakeReminderNotificationClient();
    final preferences = MemoryPreferencesStore();
    final service = GradeReminderService.test(
      controller: controller,
      notificationClient: notifications,
      preferencesLoader: () async => preferences,
      cacheStoreBuilder: (userId, studentId) => AcademicCacheStore(
        appUserId: userId,
        sourceAccountId: studentId,
        snapshotStore: vaults.putIfAbsent(
          '$userId|$studentId',
          _MemorySnapshotStore.new,
        ),
      ),
    );

    await service.setEnabled(
      enabled: true,
      userId: 'app-a',
      year: '2026',
      semester: 3,
      grades: [_grade('88')],
    );
    source.rawGrade = _rawGrade('92');
    await service.runCheckNow();
    expect(notifications.gradeUpdates, hasLength(1));

    await controller.syncAppUser('app-b');
    await controller.login(studentId: '2026000002', password: 'secret');
    await service.setEnabled(
      enabled: true,
      userId: 'app-b',
      year: '2026',
      semester: 3,
      grades: [_grade('92')],
    );
    source.rawGrade = _rawGrade('95');
    await service.runCheckNow();
    expect(notifications.gradeUpdates, hasLength(2));
    controller.dispose();
  });
}

GradeReminderService _service(
  AcademicSessionController controller,
  _MemorySnapshotStore vault,
  _FakeReminderNotificationClient notifications,
) {
  return GradeReminderService.test(
    controller: controller,
    notificationClient: notifications,
    preferencesLoader: () async => _testPreferences,
    cacheStoreBuilder: (userId, studentId) => AcademicCacheStore(
      appUserId: userId,
      sourceAccountId: studentId,
      snapshotStore: vault,
    ),
  );
}

final _testPreferences = MemoryPreferencesStore();

Future<AcademicSessionController> _loggedInController(
  _FakeAcademicDataSource source, {
  String appUserId = 'app-a',
}) async {
  final controller = AcademicSessionController(
    repository: AcademicRepositoryImpl(
      local: source,
      legacy: _FakeAcademicDataSource(_rawGrade('0')),
    ),
    cleanupCoordinator: AccountSessionCleanupCoordinator(),
  );
  await controller.syncAppUser(appUserId);
  await controller.login(studentId: '2026000001', password: 'secret');
  return controller;
}

Map<String, Object?> _rawGrade(String grade) => <String, Object?>{
      'kcmc': '数据结构',
      'jxb_id': 'class-1',
      'xh_id': 'grade-1',
      'cj': grade,
      'bfzcj': grade,
      'xf': 3,
      'jd': 4,
      'kch': 'CS101',
    };

EduGrade _grade(String grade) => EduGrade(
      name: '数据结构',
      classId: 'class-1',
      studentGradeId: 'grade-1',
      courseCode: 'CS101',
      displayGrade: grade,
      credits: 3,
      gpa: 4,
      fraction: double.parse(grade),
      isDegree: true,
    );

final class _FakeAcademicDataSource implements AcademicDataSource {
  _FakeAcademicDataSource(this.rawGrade);

  Map<String, Object?> rawGrade;
  int gradeCalls = 0;
  String? _studentId;
  SessionState _state = SessionState.unauthenticated;

  @override
  String get sourceName => '测试本机直连';
  @override
  SessionState get sessionState => _state;
  @override
  String? get studentId => _studentId;
  @override
  Future<LoginResult> login(
      {required String studentId, required String password}) async {
    _studentId = studentId;
    _state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {'test'});
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() => throw UnimplementedError();
  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) =>
      throw UnimplementedError();
  @override
  Future<StudentProfile> getProfile() async =>
      const StudentProfile(name: '', grade: '', college: '', major: '');
  @override
  Future<CourseFetchResult> getCourses(
          {required String year, required int semester}) =>
      throw UnimplementedError();
  @override
  Future<GradeFetchResult> getGrades(
      {required String year, required int semester}) async {
    gradeCalls++;
    return GradeFetchResult(grades: [RawGrade(raw: rawGrade)], pages: 1);
  }

  @override
  Future<void> resetSession() async {
    _studentId = null;
    _state = SessionState.unauthenticated;
  }

  @override
  void close() {}
}

final class _MemorySnapshotStore implements AccountScopedSnapshotStore {
  PersonalSnapshot? snapshot;
  @override
  String get accountFingerprint => 'test-fingerprint';
  @override
  Future<PersonalSnapshot?> read(
          {required PersonalDataType type,
          required String sourceSystem,
          required String sourceAccountId}) async =>
      snapshot;
  @override
  Future<void> write(
      {required PersonalDataType type,
      required int schemaVersion,
      required String sourceSystem,
      required String sourceAccountId,
      required Map<String, dynamic> payload,
      DateTime? fetchedAt,
      DateTime? expiresAt}) async {
    snapshot = PersonalSnapshot(
      appUserFingerprint: 'test',
      sourceAccountFingerprint: sourceAccountId,
      type: type,
      schemaVersion: schemaVersion,
      encryptionVersion: 1,
      fetchedAt: fetchedAt ?? DateTime.now(),
      expiresAt: expiresAt,
      contentHash: 'test',
      payload: payload,
    );
  }

  @override
  Future<void> deleteType(PersonalDataType type) async => snapshot = null;
  @override
  Future<void> clearUser() async => snapshot = null;
  @override
  Future<void> close() async {}
}

final class _FakeReminderNotificationClient
    implements ReminderNotificationClient {
  final List<({int id, String title, String body, String payload})>
      gradeUpdates = [];
  @override
  Future<void> initializeCourseReminders() async {}
  @override
  Future<bool> requestCourseReminderPermissions() async => true;
  @override
  Future<bool> scheduleCourseReminder(
          {required int id,
          required String title,
          required String body,
          required String detailText,
          required DateTime scheduledTime,
          required DateTime classStart,
          required String payload,
          required String ticker,
          required bool exactAllowWhileIdle}) async =>
      false;
  @override
  Future<void> cancelCourseReminder(int id) async {}
  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async =>
      false;
  @override
  Future<void> cancelCalendarReminder(int id) async {}

  @override
  Future<bool> showGradeUpdate(
      {required int id,
      required String title,
      required String body,
      required String payload}) async {
    gradeUpdates.add((id: id, title: title, body: body, payload: payload));
    return true;
  }
}
