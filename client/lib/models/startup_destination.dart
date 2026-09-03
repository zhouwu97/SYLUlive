import 'dart:async' show unawaited;

import '../platform/contracts/preferences_store.dart';

/// 统一启动目标模式。
///
/// 取代旧的 `startOnTimetable` bool，三者天然互斥：
/// - [home]      — 每次启动进入首页
/// - [timetable] — 每次启动直接进入课表
/// - [lastPage]  — 恢复杀后台前最后所在页面
enum StartupDestinationMode {
  home,
  timetable,
  lastPage,
}

/// [StartupDestinationMode] 的持久化与兼容迁移辅助。
///
/// 新 key: `startup_destination_mode_v1`
/// 旧 key: `start_on_timetable` (bool) — 做一次兼容迁移后不再参与导航。
class StartupDestinationStore {
  StartupDestinationStore._();

  static const String key = 'startup_destination_mode_v1';
  static const String legacyKey = 'start_on_timetable';

  /// 从已加载的 preferences 同步读取当前启动模式。
  static StartupDestinationMode read(AppPreferencesStore prefs) {
    final raw = prefs.getString(key);
    if (raw != null) return _parse(raw);
    return StartupDestinationMode.home;
  }

  /// 旧 `start_on_timetable` 一次性迁移。
  ///
  /// 条件：新 key 不存在 **且** 旧 key 存在。
  /// 迁移后新 key 写入，旧 key 保留一个版本不删除。
  static Future<void> migrateFromLegacy(AppPreferencesStore prefs) {
    migrateFromLegacySync(prefs);
    return Future.value();
  }

  /// [migrateFromLegacy] 的同步版本，供主题同步加载路径在读取前保序调用。
  ///
  /// 两种偏好存储的读缓存均为同步更新，落盘写入 fire-and-forget 不影响
  /// 紧随其后的 [read] 结果。
  static void migrateFromLegacySync(AppPreferencesStore prefs) {
    final hasNew = prefs.getString(key) != null;
    if (hasNew) return;

    final legacyValue = prefs.getBool(legacyKey);
    if (legacyValue == null) return;

    final migrated = legacyValue
        ? StartupDestinationMode.timetable
        : StartupDestinationMode.home;
    unawaited(prefs.setString(key, migrated.name));
  }

  /// 写入新模式。
  static Future<void> write(
    AppPreferencesStore prefs,
    StartupDestinationMode mode,
  ) async {
    await prefs.setString(key, mode.name);
  }

  static StartupDestinationMode _parse(String value) {
    for (final mode in StartupDestinationMode.values) {
      if (mode.name == value) return mode;
    }
    return StartupDestinationMode.home;
  }
}
