import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:characters/characters.dart';

import '../../../platform/contracts/preferences_store.dart';
import '../adapters/legacy_recent_adapter.dart';
import '../domain/emoji_asset_ref.dart';
import '../domain/emoji_asset_key.dart';
import '../domain/emoji_local_id.dart';
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

  /// 匿名使用按会话分桶的前缀。整桶键形如 `anonymous:<32 位十六进制>`。
  static const anonymousPrefix = 'anonymous:';
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  late final Future<AppPreferencesStore> _preferences = _preferencesLoader();
  Future<void> _queue = Future<void>.value();
  String? _userId;
  String? get userId => _userId;

  /// 当前匿名会话的作用域。每次认领成功后换一个新的，
  /// 于是「一个会话的数据最多被认领一次」在存储层就是真的。
  String _anonymousScope = '$anonymousPrefix${newEmojiLocalId()}';

  void switchUser(String? value) {
    final next = value?.trim();
    final normalized = next == null || next.isEmpty ? null : next;
    if (_userId == normalized) return;
    _userId = normalized;
    notifyListeners();
  }

  String _scope(String? userId) =>
      userId == null ? _anonymousScope : 'user:$userId';

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
      // 认领有两种口径，不能混成一个标记：
      // - `anonymous`（v1 迁移与升级前的旧匿名数据）是一次性的，只归首个登录账号，
      //   换账号、重启都不能再认领；
      // - `anonymous:<sessionId>` 属于某一个匿名会话，每个会话各认领一次。
      // 早期只有全局 claimed_by，结果第一次认领之后所有后续匿名使用永远认领不上。
      // 认领和清空仍在同一个持久化值里提交，崩溃后不会重复认领。
      if (_userId == null) {
        if (!prefs.containsKey(storageKey)) await _save(prefs, root);
        return List.unmodifiable(_records(root, scope));
      }
      final claimed = <EmojiRecentRecord>[];
      var claimedLegacy = false;
      if (root['claimed_by'] == null) {
        claimedLegacy = true;
        claimed.addAll(_records(root, 'anonymous'));
        root['anonymous'] = <dynamic>[];
        root['claimed_by'] = scope;
      }
      var claimedSession = false;
      for (final key in root.keys
          .where((key) => key.startsWith(anonymousPrefix))
          .toList(growable: false)) {
        final records = _records(root, key);
        if (records.isNotEmpty) {
          claimed.addAll(records);
          claimedSession = true;
        }
        root.remove(key);
      }
      if (claimed.isNotEmpty) {
        root[scope] = _merge(_records(root, scope), claimed)
            .map((record) => record.toJson())
            .toList();
      }
      if (claimedLegacy || claimedSession || !prefs.containsKey(storageKey)) {
        await _save(prefs, root);
      }
      if (claimedSession) {
        // 本会话的数据已经并入账号桶；之后的匿名使用属于新会话。
        _anonymousScope = '$anonymousPrefix${newEmojiLocalId()}';
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
