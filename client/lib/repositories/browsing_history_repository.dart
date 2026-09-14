import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import '../models/browsing_history_item.dart';

/// 浏览历史仓库（BrowsingHistoryRepository）
///
/// 本地存储用户浏览的校园资讯与帖子历史，上限 500 条，支持去重置顶与分类过滤。
/// 严格按登录账号隔离存储（browsing_history_v1_{appUserId}），游客独立使用 browsing_history_v1_guest。
class BrowsingHistoryRepository {
  static String storageKeyFor(String? userId) {
    final uid = (userId != null && userId.trim().isNotEmpty)
        ? userId.trim()
        : 'guest';
    return 'browsing_history_v1_$uid';
  }

  static const int maxCapacity = 500;

  final AppPreferencesStore Function()? _storeProvider;

  BrowsingHistoryRepository([this._storeProvider]);

  Future<AppPreferencesStore> _getStore() async {
    if (_storeProvider != null) return _storeProvider!();
    return AppPreferencesStore.getInstance();
  }

  /// 获取所有浏览记录（按访问时间倒序）
  Future<List<BrowsingHistoryItem>> getHistory({
    String? userId,
    BrowsingHistoryType? filterType,
  }) async {
    try {
      final store = await _getStore();
      final raw = store.getString(storageKeyFor(userId));
      if (raw == null || raw.trim().isEmpty) return const [];

      final list = jsonDecode(raw);
      if (list is! List) return const [];

      final items = list
          .whereType<Map<String, dynamic>>()
          .map(BrowsingHistoryItem.fromJson)
          .toList()
        ..sort((a, b) => b.viewedAt.compareTo(a.viewedAt));

      if (filterType != null) {
        return items.where((i) => i.type == filterType).toList();
      }
      return items;
    } catch (e) {
      debugPrint('加载浏览历史失败: $e');
      return const [];
    }
  }

  /// 记录一次浏览（仅在详情成功加载后调用，重复访问则更新时间并置顶）
  Future<void> recordVisit({
    String? userId,
    required String targetId,
    required BrowsingHistoryType type,
    required String title,
    String? author,
    String? cover,
  }) async {
    if (targetId.trim().isEmpty || title.trim().isEmpty) return;

    try {
      final currentList = await getHistory(userId: userId);
      final updated = List<BrowsingHistoryItem>.from(currentList);

      final now = DateTime.now();
      final existingIndex = updated.indexWhere(
        (item) => item.type == type && item.targetId == targetId,
      );

      if (existingIndex >= 0) {
        // 重复访问：更新快照与时间，移动到最顶部
        final existing = updated.removeAt(existingIndex);
        updated.insert(
          0,
          existing.copyWith(
            titleSnapshot: title.trim(),
            authorSnapshot: author?.trim() ?? existing.authorSnapshot,
            coverSnapshot: cover ?? existing.coverSnapshot,
            viewedAt: now,
          ),
        );
      } else {
        // 全新记录：插入顶部
        final newItem = BrowsingHistoryItem(
          id: '${type.name}_${targetId}_${now.millisecondsSinceEpoch}',
          targetId: targetId,
          type: type,
          titleSnapshot: title.trim(),
          authorSnapshot: author?.trim(),
          coverSnapshot: cover,
          viewedAt: now,
        );
        updated.insert(0, newItem);
      }

      // 容量限制：最多保留 500 条
      final trimmed = updated.length > maxCapacity
          ? updated.sublist(0, maxCapacity)
          : updated;

      final store = await _getStore();
      final jsonStr = jsonEncode(trimmed.map((i) => i.toJson()).toList());
      await store.setString(storageKeyFor(userId), jsonStr);
    } catch (e) {
      debugPrint('写入浏览历史失败: $e');
    }
  }

  /// 删除单条浏览记录
  Future<void> removeItem(String id, {String? userId}) async {
    try {
      final currentList = await getHistory(userId: userId);
      final updated = currentList.where((i) => i.id != id).toList();
      final store = await _getStore();
      final jsonStr = jsonEncode(updated.map((i) => i.toJson()).toList());
      await store.setString(storageKeyFor(userId), jsonStr);
    } catch (e) {
      debugPrint('删除单条浏览历史失败: $e');
    }
  }

  /// 清空全部浏览记录
  Future<void> clearAll({String? userId}) async {
    try {
      final store = await _getStore();
      await store.remove(storageKeyFor(userId));
    } catch (e) {
      debugPrint('清空浏览历史失败: $e');
    }
  }
}
