import 'package:flutter/foundation.dart';

import '../../../platform/contracts/preferences_store.dart';
import '../../campus_data/storage/academic_cache_store.dart';
import '../../campus_data/storage/schedule_cache_store.dart';
import '../../../services/course_reminder_service.dart';
import '../../../services/home_widget_service.dart';
import 'academic_storage_preferences.dart';
import 'academic_persistence_gate.dart';

typedef AcademicAuxiliaryCleanup = Future<void> Function();

/// 教务资料保存策略。
///
/// 该策略只控制成绩、课表、Profile 及相关提醒/小组件的持久化，不控制
/// 学校 Cookie，也不把服务端法律授权字段当成本机保存许可。
final class AcademicPersistencePolicy extends ChangeNotifier
    implements AcademicPersistenceGate {
  AcademicPersistencePolicy({
    required String appUserId,
    required AppPreferencesStore preferences,
    required this.academicStore,
    required this.scheduleStore,
    this.auxiliaryCleanup,
    bool supported = true,
  })  : preferences = AcademicStoragePreferences(
          appUserId: appUserId,
          store: preferences,
        ),
        _supported = supported;

  final AcademicStoragePreferences preferences;
  final AcademicCacheStore? academicStore;
  final ScheduleCacheStore? scheduleStore;
  final AcademicAuxiliaryCleanup? auxiliaryCleanup;
  final bool _supported;
  bool _loaded = false;

  bool get isSupported => _supported;
  @override
  bool get allowPersonalDataPersistence =>
      _supported &&
      _loaded &&
      preferences.saveAcademicData &&
      !preferences.cleanupPending;
  @override
  bool get allowPersonalDataRead => allowPersonalDataPersistence;
  bool get saveAcademicData => preferences.saveAcademicData;
  bool get cleanupPending => preferences.cleanupPending;

  Future<void> load() async {
    _loaded = true;
    notifyListeners();
  }

  Future<void> enable() async {
    if (!_supported) throw StateError('当前平台不支持本机教务资料保险箱');
    await preferences.setSaveAcademicData(true);
    await preferences.setCleanupPending(false);
    await preferences.markMigrated();
    _loaded = true;
    AcademicPersistenceRegistry.set(
      preferences.appUserId,
      enabled: true,
    );
    notifyListeners();
  }

  /// 只有所有清理动作成功后才把开关切换为关闭，避免 UI 与磁盘状态分离。
  Future<void> disableAndClear() async {
    _loaded = true;
    try {
      await academicStore?.clearAll();
      await scheduleStore?.clearAll();
      await auxiliaryCleanup?.call();
      await preferences.setSaveAcademicData(false);
      await preferences.setCleanupPending(false);
      await preferences.markMigrated();
      AcademicPersistenceRegistry.set(
        preferences.appUserId,
        enabled: false,
      );
    } catch (error) {
      try {
        await preferences.setCleanupPending(true);
      } catch (_) {}
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> clearAcademicData() => disableAndClear();

  Future<void> close() async {
    await academicStore?.close();
    await scheduleStore?.close();
  }

  /// 清理教务相关的小组件数据和提醒；考试小组件不是教务课表数据，保留。
  static Future<void> clearAuxiliaryData() async {
    await HomeWidgetService.clearCourseData();
    await CourseReminderService.instance.cancelCourseReminders();
  }
}
