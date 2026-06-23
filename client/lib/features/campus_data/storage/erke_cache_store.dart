import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../erke/erke_models.dart';

/// 二课数据本地缓存
///
/// 包装 SharedPreferences，兼容旧缓存键:
///   - `erke_scores_cache` → activities JSON
///   - `erke_summary_cache` → legacy summary (迁移后不覆盖)
///
/// 新键:
///   - `erke_snapshot` → ErkeSnapshot JSON
class ErkeCacheStore {
  static const _keyScores = 'erke_scores_cache';
  static const _keySummary = 'erke_summary_cache';
  static const _keySnapshot = 'erke_snapshot';

  // ================================================================
  //  读取
  // ================================================================

  /// 读取完整快照 (新格式)
  Future<ErkeSnapshot?> loadSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySnapshot);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ErkeSnapshot.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 读取活动列表 (兼容旧缓存)
  Future<List<ErkeActivity>> loadActivities() async {
    final snapshot = await loadSnapshot();
    if (snapshot != null && snapshot.hasActivities) {
      return snapshot.activities;
    }

    // 回退旧缓存
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyScores);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => ErkeActivity.fromLegacyMap(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取毕业要求
  Future<ErkeGraduationSummary?> loadGraduation() async {
    final snapshot = await loadSnapshot();
    return snapshot?.graduation;
  }

  /// 读取学年要求 (默认年)
  Future<ErkeYearlySummary?> loadYearly() async {
    final snapshot = await loadSnapshot();
    return snapshot?.yearly;
  }

  /// 读取指定学年的汇总缓存
  Future<ErkeYearlySummary?> loadYearlyForYear(String year) async {
    final snapshot = await loadSnapshot();
    return snapshot?.yearlyByYear[year];
  }

  /// 检查是否有缓存
  Future<bool> hasCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_keySnapshot) ||
        prefs.containsKey(_keyScores);
  }

  // ================================================================
  //  写入
  // ================================================================

  /// 原子写入完整快照
  Future<void> saveSnapshot(ErkeSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySnapshot, json.encode(snapshot.toJson()));
  }

  /// 更新或合并学年汇总到快照中
  Future<void> saveYearlySummary(ErkeYearlySummary yearly) async {
    final snapshot = await loadSnapshot();
    final merged = ErkeSnapshot(
      graduation: snapshot?.graduation,
      yearly: yearly,
      yearlyByYear: {
        ...?snapshot?.yearlyByYear,
        yearly.year: yearly,
      },
      activities: snapshot?.activities ?? [],
      fetchedAt: DateTime.now(),
    );
    await saveSnapshot(merged);
  }

  /// 写入活动列表 (轻量，不覆盖其他数据)
  Future<void> saveActivities(List<ErkeActivity> activities) async {
    final snapshot = await loadSnapshot();
    final merged = ErkeSnapshot(
      graduation: snapshot?.graduation,
      yearly: snapshot?.yearly,
      yearlyByYear: snapshot?.yearlyByYear ?? {},
      activities: activities,
      fetchedAt: DateTime.now(),
    );
    await saveSnapshot(merged);
  }

  /// 原子写入完整的 fetch 结果
  Future<void> saveFullResult({
    required ErkeGraduationSummary graduation,
    required ErkeYearlySummary yearly,
    required List<ErkeActivity> activities,
  }) async {
    final snapshot = ErkeSnapshot(
      graduation: graduation,
      yearly: yearly,
      yearlyByYear: {yearly.year: yearly},
      activities: activities,
      fetchedAt: DateTime.now(),
    );
    await saveSnapshot(snapshot);
  }

  // ================================================================
  //  清理
  // ================================================================

  /// 清除所有缓存
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySnapshot);
    await prefs.remove(_keyScores);
    await prefs.remove(_keySummary);
  }
}
