import '../models/edu_grade.dart';
import '../models/grade_reminder_status.dart';

/// 成绩提醒已按学校能力迁移方案关闭。
///
/// 保留兼容外观，避免旧页面或旧版本状态恢复时引入破坏性 API 变更；所有
/// 方法均为本地无副作用，不创建后台任务、不申请通知权限，也不访问服务端。
class GradeReminderService {
  GradeReminderService._();

  static final GradeReminderService instance = GradeReminderService._();

  Future<GradeReminderStatus> getStatus({String? userId}) async {
    return const GradeReminderStatus.unsupported();
  }

  Future<bool> isEnabled({required String userId}) async => false;

  Future<void> syncRuntimeConfig({required String? userId}) async {}

  Future<void> ensureScheduledIfEnabled() async {}

  Future<void> runCheckNow() async {}

  Future<GradeReminderStatus> setEnabled({
    required bool enabled,
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    return const GradeReminderStatus.unsupported();
  }

  Future<void> syncBaselineIfEnabled({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {}

  Future<void> syncBaseline({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {}

  Future<void> syncSelectedSemester({
    required String userId,
    required String year,
    required int semester,
  }) async {}

  Future<void> clearForUser(String userId) async {}

  Future<void> clearGradeUpdateNotifications() async {}

  Future<bool> openNotificationSettings() async => false;

  Future<bool> openKeepAliveSettings() async => false;

  Future<bool> requestNotificationPermission() async => false;
}
