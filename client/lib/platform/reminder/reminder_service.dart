import 'dart:async';

import '../app_platform.dart';

/// 课表 / 考试 / 成绩等学业提醒能力的服务接口。
///
/// 计划 11.2：当前 Android 提醒逻辑分散在 `services/course_reminder_service.dart`
/// 与 `services/grade_reminder_service.dart`（早期直接使用 `dart:io` 平台判断）。
/// 鸿蒙阶段（计划阶段 9 实况窗）将通过 ArkTS `FormExtensionAbility`
/// 与本接口下游实现联动。在该实现经过真机验收前，[isSupported] 必须为 false。
abstract class ReminderService {
  AppPlatform get platform;
  bool get isSupported;

  /// 预约一次课表提醒。
  ///
  /// `notificationId` 必须稳定唯一；同一 ID 重复调用应覆盖而非追加。
  Future<void> scheduleCourseReminder({
    required int notificationId,
    required String title,
    required String body,
    required DateTime triggerAt,
  });

  Future<void> cancelCourseReminder(int notificationId);

  /// 取消全部待触发的学业提醒。
  Future<void> cancelAllCourseReminders();

  Future<void> dispose();
}

class NoopReminderService implements ReminderService {
  const NoopReminderService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<void> scheduleCourseReminder({
    required int notificationId,
    required String title,
    required String body,
    required DateTime triggerAt,
  }) async {}

  @override
  Future<void> cancelCourseReminder(int notificationId) async {}

  @override
  Future<void> cancelAllCourseReminders() async {}

  @override
  Future<void> dispose() async {}
}