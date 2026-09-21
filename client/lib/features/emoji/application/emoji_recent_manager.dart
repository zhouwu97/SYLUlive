import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:characters/characters.dart';

import '../../../platform/contracts/preferences_store.dart';
import '../adapters/legacy_recent_adapter.dart';
import '../domain/emoji_asset_ref.dart';
import '../domain/emoji_asset_key.dart';
import '../domain/emoji_recent_record.dart';

/// 写操作串行提交；账号在调用时捕获，避免网络返回后写入另一个账号。
class EmojiRecentManager extends ChangeNotifier {
  EmojiRecentManager(
      {Future<AppPreferencesStore> Function()? preferencesLoader})
      : _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  static final instance = EmojiRecentManager();
  static const storageKey = 'emoji_recent_v2';
  static const maxCount = 100;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  late final Future<AppPreferencesStore> _preferences = _preferencesLoader();
  Future<void> _queue = Future<void>.value();
  String? _userId;
  String? get userId => _userId;

  void switchUser(String? value) {
    final next = value?.trim();
    final normalized = next == null || next.isEmpty ? null : next;
    if (_userId == normalized) return;
    _userId = normalized;
    notifyListeners();
  }

  String _scope(String? userId) =>
      userId == null ? 'anonymous' : 'user:$userId';

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Map<String, dynamic>> _read(AppPreferencesStore prefs) async {
    final raw = prefs.getString(storageKey);
    if (raw != null) return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final legacy = const LegacyRecentAdapter().adapt(
      prefs.getStringList('emoji_recent_v1') ?? const [],
    );
    return {'anonymous': legacy.map((e) => e.toJson()).toList()};
  }

  List<EmojiRecentRecord> _records(Map<String, dynamic> root, String scope) =>
      ((root[scope] as List?) ?? const [])
          .map((e) =>
              EmojiRecentRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();

  Future<void> _save(
      AppPreferencesStore prefs, Map<String, dynamic> root) async {
    if (!await prefs.setString(storageKey, jsonEncode(root))) {
      throw StateError('最近使用记录保存失败');
    }
    notifyListeners();
  }

  Future<List<EmojiRecentRecord>> load() {
    final scope = _scope(_userId);
    return _serialized(() async {
      final prefs = await _preferences;
      final root = await _read(prefs);
      // 首次认领和匿名空间清空在同一个持久化值中提交，崩溃后不会重复认领。
      if (scope != 'anonymous' && root['claimed_by'] == null) {
        root[scope] = _merge(_records(root, scope), _records(root, 'anonymous'))
            .map((e) => e.toJson())
            .toList();
        root['anonymous'] = <dynamic>[];
        root['claimed_by'] = scope;
        await _save(prefs, root);
      } else if (!prefs.containsKey(storageKey)) {
        await _save(prefs, root);
      }
      return List.unmodifiable(_records(root, scope));
    });
  }

  List<EmojiRecentRecord> _merge(
      Iterable<EmojiRecentRecord> a, Iterable<EmojiRecentRecord> b) {
    final byKey = <String, EmojiRecentRecord>{};
    for (final record in [...a, ...b]) {
      final previous = byKey[record.assetKey];
      byKey[record.assetKey] = previous == null
          ? record
          : EmojiRecentRecord(
              assetKey: record.assetKey,
              packId: record.packId ?? previous.packId,
              lastUsedAt: record.lastUsedAt.isAfter(previous.lastUsedAt)
                  ? record.lastUsedAt
                  : previous.lastUsedAt,
              useCount: math.max(record.useCount, previous.useCount),
            );
    }
    final records = byKey.values.toList()
      ..sort((a, b) {
        final time = b.lastUsedAt.compareTo(a.lastUsedAt);
        return time == 0 ? a.assetKey.compareTo(b.assetKey) : time;
      });
    return records.take(maxCount).toList();
  }

  Future<void> recordSent(EmojiAssetRef asset, {required String? accountId}) =>
      recordBatchSent([asset], accountId: accountId);

  Future<void> recordBatchSent(Iterable<EmojiAssetRef> assets,
      {required String? accountId}) {
    final keys = assets.map((e) => e.assetKey).toSet();
    if (keys.isEmpty) return Future.value();
    final scope = _scope(accountId);
    return _serialized(() async {
      final prefs = await _preferences;
      final root = await _read(prefs);
      final existing = _records(root, scope);
      final now = DateTime.now().toUtc();
      final next = keys.map((key) {
        final old = existing.where((e) => e.assetKey == key).firstOrNull;
        return EmojiRecentRecord(
            assetKey: key,
            lastUsedAt: now,
            useCount: (old?.useCount ?? 0) + 1,
            packId: EmojiAssetKey.parse(key).packId);
      });
      root[scope] = _merge(existing, next).map((e) => e.toJson()).toList();
      await _save(prefs, root);
    });
  }

  Future<void> merge(Iterable<EmojiRecentRecord> incoming) {
    final scope = _scope(_userId);
    return _serialized(() async {
      final prefs = await _preferences;
      final root = await _read(prefs);
      final clearedAt =
          DateTime.tryParse(root['cleared:$scope']?.toString() ?? '');
      root[scope] = _merge(
              _records(root, scope),
              incoming.where(
                  (e) => clearedAt == null || e.lastUsedAt.isAfter(clearedAt)))
          .map((e) => e.toJson())
          .toList();
      await _save(prefs, root);
    });
  }

  Future<void> clear() {
    final scope = _scope(_userId);
    return _serialized(() async {
      final prefs = await _preferences;
      final root = await _read(prefs);
      root[scope] = <dynamic>[];
      root['cleared:$scope'] = DateTime.now().toUtc().toIso8601String();
      await _save(prefs, root);
    });
  }

  static final _emojiPattern = RegExp(
      r'\p{Extended_Pictographic}|\p{Regional_Indicator}|\u20e3',
      unicode: true);

  static Iterable<EmojiAssetRef> unicodeIn(String text) => text.characters
      .where(_emojiPattern.hasMatch)
      .map((e) => EmojiAssetRef(assetKey: 'unicode:$e'));

  /// 附属记录失败不能把已被服务器确认的消息改成发送失败。
  Future<void> recordConfirmed(Iterable<EmojiAssetRef> assets,
      {required String? accountId}) async {
    try {
      await recordBatchSent(assets, accountId: accountId);
    } catch (error) {
      debugPrint('保存最近使用失败: $error');
    }
  }
}
