import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import '../models/schedule/schedule_override.dart';

/// 存储或重叠校验异常
class ScheduleOverrideOverlapException implements Exception {
  final String message;
  final Set<int> overlappingWeeks;
  final ScheduleOverride existingOverride;

  const ScheduleOverrideOverlapException({
    required this.message,
    required this.overlappingWeeks,
    required this.existingOverride,
  });

  @override
  String toString() => 'ScheduleOverrideOverlapException: $message';
}

/// 本地课表调整仓库（ScheduleOverrideRepository）
///
/// 负责持久化保存 ScheduleOverride，并严格执行 Section 11 的重叠禁止规则。
class ScheduleOverrideRepository {
  final AppPreferencesStore Function()? _preferencesStoreProvider;

  ScheduleOverrideRepository([this._preferencesStoreProvider]);

  Future<AppPreferencesStore> _getStore() async {
    if (_preferencesStoreProvider != null) {
      return _preferencesStoreProvider!();
    }
    return AppPreferencesStore.getInstance();
  }

  static String _storageKey(String semesterId, String? accountId) {
    final acc = (accountId != null && accountId.trim().isNotEmpty)
        ? accountId.trim()
        : 'default_account';
    return 'schedule_overrides_v1_${acc}_$semesterId';
  }

  /// 加载指定学期的所有调整规则
  Future<List<ScheduleOverride>> loadOverrides({
    required String semesterId,
    String? accountId,
  }) async {
    try {
      final store = await _getStore();
      final key = _storageKey(semesterId, accountId);
      final raw = store.getString(key);
      if (raw == null || raw.trim().isEmpty) return const [];

      final list = jsonDecode(raw);
      if (list is! List) return const [];

      return list
          .whereType<Map<String, dynamic>>()
          .map(ScheduleOverride.fromJson)
          .toList();
    } catch (e) {
      debugPrint('加载本地调课规则失败: $e');
      return const [];
    }
  }

  /// 保存指定学期的所有调整规则
  Future<bool> saveOverrides({
    required String semesterId,
    required List<ScheduleOverride> overrides,
    String? accountId,
  }) async {
    try {
      final store = await _getStore();
      final key = _storageKey(semesterId, accountId);
      final jsonStr = jsonEncode(overrides.map((o) => o.toJson()).toList());
      return await store.setString(key, jsonStr);
    } catch (e) {
      debugPrint('保存本地调课规则失败: $e');
      return false;
    }
  }

  /// 校验规则是否与已有活跃规则在 affectedWeeks 上相交（Section 11 强约束）
  void validateNoOverlap({
    required ScheduleOverride candidate,
    required List<ScheduleOverride> existingList,
    String? editingOverrideId,
  }) {
    if (!candidate.isActive) return;

    for (final existing in existingList) {
      if (editingOverrideId != null && existing.id == editingOverrideId) {
        continue;
      }
      if (existing.id == candidate.id) continue;
      if (!existing.isActive) continue;

      // 必须是同一个 meetingKey
      if (existing.meetingKey == candidate.meetingKey) {
        final overlap =
            existing.affectedWeeks.intersection(candidate.affectedWeeks);
        if (overlap.isNotEmpty) {
          final sortedOverlap = overlap.toList()..sort();
          throw ScheduleOverrideOverlapException(
            message:
                '第${sortedOverlap.first}-${sortedOverlap.last}周已有本地调整，禁止重复添加',
            overlappingWeeks: overlap,
            existingOverride: existing,
          );
        }
      }
    }
  }

  /// 新增或更新单条 Override
  Future<bool> upsertOverride({
    required ScheduleOverride override,
    String? accountId,
  }) async {
    final current = await loadOverrides(
      semesterId: override.semesterId,
      accountId: accountId,
    );

    // 校验周次相交规则
    validateNoOverlap(
      candidate: override,
      existingList: current,
      editingOverrideId: override.id,
    );

    final updated = List<ScheduleOverride>.from(current);
    final idx = updated.indexWhere((o) => o.id == override.id);
    if (idx >= 0) {
      updated[idx] = override;
    } else {
      updated.add(override);
    }

    return saveOverrides(
      semesterId: override.semesterId,
      overrides: updated,
      accountId: accountId,
    );
  }

  /// 删除某条调整规则（恢复教务原课）
  Future<bool> deleteOverride({
    required String overrideId,
    required String semesterId,
    String? accountId,
  }) async {
    final current = await loadOverrides(
      semesterId: semesterId,
      accountId: accountId,
    );
    final updated = current.where((o) => o.id != overrideId).toList();
    return saveOverrides(
      semesterId: semesterId,
      overrides: updated,
      accountId: accountId,
    );
  }

  /// 清空某学期的所有调整规则
  Future<bool> clearOverrides({
    required String semesterId,
    String? accountId,
  }) async {
    final store = await _getStore();
    final key = _storageKey(semesterId, accountId);
    return await store.remove(key);
  }
}
