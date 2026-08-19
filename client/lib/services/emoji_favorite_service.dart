import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../platform/contracts/preferences_store.dart';
import 'emoji_favorite_repository.dart';

enum EmojiFavoriteType { sticker, image }

class EmojiFavoriteItem {
  const EmojiFavoriteItem._({
    required this.type,
    this.stickerId,
    this.imageUrl,
    this.serverId,
    this.assetId,
    this.fileId,
    this.thumbnailUrl,
    this.mimeType,
    this.isAnimated = false,
    this.compressedSize,
    this.sortOrder,
    this.quotaUsed,
  });

  const EmojiFavoriteItem.sticker(String stickerId)
      : this._(
          type: EmojiFavoriteType.sticker,
          stickerId: stickerId,
        );

  const EmojiFavoriteItem.image(String imageUrl)
      : this._(
          type: EmojiFavoriteType.image,
          imageUrl: imageUrl,
        );

  const EmojiFavoriteItem.custom({
    int? serverId,
    int? assetId,
    required int fileId,
    String? imageUrl,
    String? thumbnailUrl,
    String? mimeType,
    bool isAnimated = false,
    int? compressedSize,
    int? sortOrder,
    int? quotaUsed,
  }) : this._(
          type: EmojiFavoriteType.image,
          imageUrl: imageUrl,
          serverId: serverId,
          assetId: assetId,
          fileId: fileId,
          thumbnailUrl: thumbnailUrl,
          mimeType: mimeType,
          isAnimated: isAnimated,
          compressedSize: compressedSize,
          sortOrder: sortOrder,
          quotaUsed: quotaUsed,
        );

  final EmojiFavoriteType type;
  final String? stickerId;
  final String? imageUrl;
  final int? serverId;
  final int? assetId;
  final int? fileId;
  final String? thumbnailUrl;
  final String? mimeType;
  final bool isAnimated;
  final int? compressedSize;
  final int? sortOrder;
  final int? quotaUsed;

  String get key => switch (type) {
        EmojiFavoriteType.sticker => 'sticker:${stickerId ?? ''}',
        EmojiFavoriteType.image =>
          'image:${imageUrl ?? 'file:${fileId ?? assetId ?? serverId ?? ''}'}',
      };

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (stickerId != null) 'sticker_id': stickerId,
        if (imageUrl != null) 'image_url': imageUrl,
        if (serverId != null) 'id': serverId,
        if (assetId != null) 'asset_id': assetId,
        if (fileId != null) 'file_id': fileId,
        if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
        if (mimeType != null) 'mime_type': mimeType,
        if (isAnimated) 'is_animated': true,
        if (compressedSize != null) 'compressed_size': compressedSize,
        if (sortOrder != null) 'sort_order': sortOrder,
        if (quotaUsed != null) 'quota_used': quotaUsed,
      };

  /// 解析服务端 builtin/custom 协议，同时兼容本地 v1 的 type/image_url。
  factory EmojiFavoriteItem.fromApiJson(Map<String, dynamic> value) {
    final kind = value['kind']?.toString() ?? value['type']?.toString();
    final isSticker =
        kind == 'builtin' || kind == EmojiFavoriteType.sticker.name;
    final stickerId = _asString(value['sticker_id']);
    final imageUrl = _asString(value['url']) ?? _asString(value['image_url']);
    if (isSticker) {
      final id = stickerId;
      if (id == null) throw const FormatException('内置表情缺少 sticker_id');
      return EmojiFavoriteItem._(
        type: EmojiFavoriteType.sticker,
        stickerId: id,
        serverId: _asInt(value['id']),
        sortOrder: _asInt(value['sort_order']),
        quotaUsed: _asInt(value['quota_used']),
      );
    }
    if (kind != 'custom' && kind != EmojiFavoriteType.image.name) {
      throw const FormatException('未知表情收藏类型');
    }
    if ((imageUrl == null || imageUrl.isEmpty) &&
        _asInt(value['file_id']) == null) {
      throw const FormatException('自定义表情缺少文件信息');
    }
    return EmojiFavoriteItem._(
      type: EmojiFavoriteType.image,
      imageUrl: imageUrl,
      serverId: _asInt(value['id']),
      assetId: _asInt(value['asset_id']),
      fileId: _asInt(value['file_id']),
      thumbnailUrl:
          _asString(value['thumbnail_url']) ?? _asString(value['thumb_url']),
      mimeType: _asString(value['mime_type']),
      isAnimated: _asBool(value['is_animated']),
      compressedSize: _asInt(value['compressed_size']),
      sortOrder: _asInt(value['sort_order']),
      quotaUsed: _asInt(value['quota_used']),
    );
  }

  static EmojiFavoriteItem? fromJson(Object? value) {
    if (value is! Map) return null;
    try {
      return EmojiFavoriteItem.fromApiJson(Map<String, dynamic>.from(value));
    } on FormatException {
      return null;
    }
  }
}

String? _asString(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  return value?.toString().toLowerCase() == 'true' || value == 1;
}

/// 一次异步操作开始时对当前账号的只读快照。
///
/// 所有跨网络 await 的收藏操作都以快照为准：若操作期间账号已切换
/// （epoch 或 userId 变化），[stale] 变 true，操作应静默丢弃结果，
/// 绝不触碰新账号的 `_cache`，也绝不把旧账号数据写入新账号缓存键。
class _AccountSnapshot {
  _AccountSnapshot.capture(EmojiFavoriteService service)
      : service = service,
        userId = service._userId,
        cacheKey = service.accountStorageKey,
        sessionEpoch = service._sessionEpoch,
        items = service._cache == null
            ? <EmojiFavoriteItem>[]
            : List<EmojiFavoriteItem>.from(service._cache!);

  final EmojiFavoriteService service;
  final String? userId;
  final String cacheKey;
  final int sessionEpoch;
  final List<EmojiFavoriteItem> items;

  bool get stale =>
      sessionEpoch != service._sessionEpoch || userId != service._userId;

  static bool isStaleFor(
    EmojiFavoriteService service,
    int sessionEpoch,
    String? userId,
  ) =>
      sessionEpoch != service._sessionEpoch || userId != service._userId;
}

/// 表情收藏存储。
///
/// 收藏仅保存表情 ID 或服务端图片地址，不复制原图，避免偏好存储膨胀。
class EmojiFavoriteService extends ChangeNotifier {
  EmojiFavoriteService({
    Future<AppPreferencesStore> Function()? preferencesLoader,
    String? userId,
    this.repository,
  }) : _preferencesLoader =
          preferencesLoader ?? AppPreferencesStore.getInstance,
       _userId = userId?.trim().isEmpty == true ? null : userId?.trim();

  static EmojiFavoriteService? _sharedInstance;
  static EmojiFavoriteService get instance =>
      _sharedInstance ??= EmojiFavoriteService();

  /// 绑定应用级共享服务，使各页面复用同一个账号云端收藏状态。
  static void configureSharedInstance(EmojiFavoriteService service) {
    if (identical(_sharedInstance, service)) return;
    _sharedInstance = service;
  }

  @visibleForTesting
  static void resetSharedInstanceForTesting() {
    _sharedInstance = null;
  }

  static const String storageKey = 'emoji_favorites_v1';
  static const int maxFavoriteCount = 80;

  /// 全局 v1 迁移认领标记：记录当前正在/已经认领全局 v1 收藏的账号，
  /// 防止 A 迁移中途崩溃后 B 把 A 的旧收藏认领走（见 [_migrateV1IfNeeded]）。
  static const String migrationClaimKey = 'emoji_favorites_v1_claimed_user';

  final Future<AppPreferencesStore> Function() _preferencesLoader;

  /// 可选的云端仓储引用，保持服务与本地缓存解耦。
  final EmojiFavoriteRepository? repository;
  String? _userId;
  Future<AppPreferencesStore>? _loadingPreferences;
  List<EmojiFavoriteItem>? _cache;
  Future<void>? _syncing;
  int _sessionEpoch = 0;
  bool _remoteSynced = false;

  /// 当前账号的缓存键；未登录时继续读写旧 v1 键。
  String get accountStorageKey =>
      _userId == null ? storageKey : 'emoji_favorites_cache_v2_${_userId!}';

  String? get userId => _userId;

  /// 账号切换时丢弃旧账号内存数据，避免跨账号短暂显示收藏。
  void switchUser(String? userId) {
    final normalized = userId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _userId) return;
    _userId = next;
    _sessionEpoch++;
    _cache = null;
    _syncing = null;
    _remoteSynced = false;
    notifyListeners();
  }

  /// 在 ProxyProvider.update 构建期同步账号，避免在构建阶段调用 notifyListeners 导致断言错误。
  void syncSessionUser(String? userId) {
    final normalized = userId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _userId) return;
    _userId = next;
    _sessionEpoch++;
    _cache = null;
    _syncing = null;
    _remoteSynced = false;
  }

  Future<AppPreferencesStore> get _preferences =>
      _loadingPreferences ??= _preferencesLoader();

  Future<List<EmojiFavoriteItem>> load([String? requestedUserId]) async {
    if (requestedUserId != null && requestedUserId.trim() != _userId) {
      switchUser(requestedUserId);
    }
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);

    // 解析完成前账号可能切换：锚定本次的目标账号与缓存键，切换后丢弃结果。
    final targetUserId = _userId;
    final targetEpoch = _sessionEpoch;
    final targetKey = accountStorageKey;

    final preferences = await _preferences;
    if (_AccountSnapshot.isStaleFor(this, targetEpoch, targetUserId)) {
      return <EmojiFavoriteItem>[];
    }
    final raw = preferences.getString(targetKey);
    var items = <EmojiFavoriteItem>[];
    if (raw?.isNotEmpty == true) {
      try {
        final decoded = jsonDecode(raw!);
        if (decoded is List) {
          for (final value in decoded) {
            final item = EmojiFavoriteItem.fromJson(value);
            if (item != null && !items.any((entry) => entry.key == item.key)) {
              items.add(item);
            }
          }
        }
      } catch (_) {
        // 损坏的本地收藏不应阻断表情面板，后续写入时会自动修复。
      }
    }

    if (targetUserId != null) {
      items = await _migrateV1IfNeeded(
        preferences,
        items,
        targetUserId,
        targetEpoch,
      );
    }
    if (_AccountSnapshot.isStaleFor(this, targetEpoch, targetUserId)) {
      return <EmojiFavoriteItem>[];
    }

    _cache = items.take(maxFavoriteCount).toList(growable: true);
    if (repository != null && _userId != null && !_remoteSynced) {
      await syncFromServer();
    }
    // sync 期间可能切号（_cache 已被清空）；重校验后丢弃过时结果，避免空指针/串号。
    if (_AccountSnapshot.isStaleFor(this, targetEpoch, targetUserId)) {
      return <EmojiFavoriteItem>[];
    }
    return List.unmodifiable(_cache!);
  }

  Future<List<EmojiFavoriteItem>> _migrateV1IfNeeded(
    AppPreferencesStore preferences,
    List<EmojiFavoriteItem> currentItems,
    String expectedUserId,
    int expectedEpoch,
  ) async {
    bool stale() =>
        _AccountSnapshot.isStaleFor(this, expectedEpoch, expectedUserId);
    if (stale()) return currentItems;

    final flagKey = 'emoji_favorites_v1_migrated_$expectedUserId';
    final cacheKey = 'emoji_favorites_cache_v2_$expectedUserId';
    if (preferences.getBool(flagKey) == true) {
      return currentItems;
    }

    // 全局 claim：A 先认领全局 v1；若中途崩溃（migrated=true 与 remove(v1)
    // 之间），claim 仍归 A，B 不允许把 A 的旧收藏认领走。
    final claimed = preferences.getString(migrationClaimKey);
    if (claimed != null && claimed != expectedUserId) {
      return currentItems;
    }

    final rawV1 = preferences.getString(storageKey);
    final merged = <EmojiFavoriteItem>[...currentItems];
    var hadV1 = false;
    if (rawV1?.isNotEmpty == true) {
      if (stale()) return currentItems;
      hadV1 = true;
      try {
        final decoded = jsonDecode(rawV1!);
        if (decoded is List) {
          for (final value in decoded) {
            final item = EmojiFavoriteItem.fromJson(value);
            if (item != null && !merged.any((entry) => entry.key == item.key)) {
              merged.add(item);
            }
          }
        }
      } catch (_) {
        // 忽略损坏的旧数据
      }
    }

    if (stale()) return currentItems;
    if (hadV1) {
      // 先声明归属再写数据，保证任意顺序崩溃都不会把 v1 交给他人。
      await preferences.setString(migrationClaimKey, expectedUserId);
    }
    if (stale()) return currentItems;
    // 安全时序：1. 成功写 v2 账号缓存 -> 2. 写 migrated 标记 -> 3. 最后删除旧 v1
    await preferences.setString(
      cacheKey,
      jsonEncode(merged.map((item) => item.toJson()).toList()),
    );
    await preferences.setBool(flagKey, true);
    if (hadV1) {
      await preferences.remove(storageKey);
      await preferences.remove(migrationClaimKey);
    }
    return merged;
  }

  /// 拉取当前账号收藏。失败时保留本地缓存，下一次加载继续尝试。
  Future<void> syncFromServer() async {
    if (repository == null || _userId == null) return;
    final running = _syncing;
    if (running != null) {
      await running;
      return;
    }
    final future = _syncRemote(_sessionEpoch, _userId!);
    _syncing = future;
    try {
      await future;
    } finally {
      if (identical(_syncing, future)) _syncing = null;
    }
  }

  Future<void> _syncRemote(int sessionEpoch, String expectedUserId) async {
    final expectedCacheKey = 'emoji_favorites_cache_v2_$expectedUserId';
    bool stale() => _AccountSnapshot.isStaleFor(this, sessionEpoch, expectedUserId);

    try {
      final page = await repository!.fetchFavorites();
      if (stale()) return;
      final serverItems = List<EmojiFavoriteItem>.from(page.items);
      final localCache = _cache == null
          ? <EmojiFavoriteItem>[]
          : List<EmojiFavoriteItem>.from(_cache!);

      // 将本地尚未上云的旧收藏（serverId == null）上传至服务端
      for (final local in localCache) {
        if (stale()) return;
        if (local.serverId == null) {
          try {
            EmojiFavoriteItem? uploaded;
            if (local.type == EmojiFavoriteType.sticker &&
                local.stickerId != null &&
                local.stickerId!.isNotEmpty) {
              uploaded = await repository!.createBuiltin(local.stickerId!);
            } else if (local.fileId != null && local.fileId! > 0) {
              uploaded = await repository!.createCustom(local.fileId!);
            } else if (local.imageUrl != null && local.imageUrl!.isNotEmpty) {
              uploaded = await repository!.createFromPublicImage(local.imageUrl!);
            }
            if (stale()) return;
            if (uploaded != null) {
              final existIdx = serverItems.indexWhere((m) => m.key == uploaded!.key);
              if (existIdx >= 0) {
                serverItems[existIdx] = uploaded;
              } else {
                serverItems.add(uploaded);
              }
            }
          } on EmojiFavoriteException {
            // 单个失败不阻断其余上传
          } on DioException {
            // 兼容自定义仓储直接抛出的 Dio 异常
          } catch (e) {
            debugPrint('Error uploading local favorite to cloud: $e');
          }
        }
      }

      if (stale()) return;
      final merged = <EmojiFavoriteItem>[...serverItems];
      for (final local in localCache) {
        if (local.serverId == null && !merged.any((m) => m.key == local.key)) {
          merged.add(local);
        }
      }
      final next =
          _dedupe(merged).take(maxFavoriteCount).toList(growable: true);
      if (stale()) return;
      _cache = next;
      _remoteSynced = true;
      await _persist(expectedCacheKey, next);
      notifyListeners();
    } on EmojiFavoriteException {
      // 离线时继续展示上一次缓存。
    } on DioException {
      // 兼容自定义仓储直接抛出的 Dio 异常。
    }
  }

  Future<bool> containsSticker(String stickerId) async {
    final normalized = stickerId.trim();
    if (normalized.isEmpty) return false;
    return (await load()).any(
      (item) =>
          item.type == EmojiFavoriteType.sticker &&
          item.stickerId == normalized,
    );
  }

  Future<bool> containsImage(String imageUrl) async {
    final normalized = imageUrl.trim();
    if (normalized.isEmpty) return false;
    return (await load()).any(
      (item) =>
          item.type == EmojiFavoriteType.image &&
          (item.imageUrl == normalized || item.thumbnailUrl == normalized),
    );
  }

  Future<bool> toggleSticker(String stickerId) =>
      _toggleStickerRemoteAware(stickerId.trim());

  Future<bool> toggleImage(String imageUrl) =>
      _toggleImageRemoteAware(imageUrl.trim());

  /// 冻结操作发起时的账号会话，然后 await load()，返回后校验会话未变。
  ///
  /// 关键：快照必须在 load() **之前** 冻结，否则若 load 期间发生切号，
  /// 外层操作会以新账号（B）身份继续执行，把 A 发起的操作变成对 B 的操作。
  /// 返回 null 表示 load 期间已切号——调用方必须放弃本次操作。
  Future<_AccountSnapshot?> _loadSnapshotForOperation() async {
    final expectedEpoch = _sessionEpoch;
    final expectedUserId = _userId;
    await load();
    if (_AccountSnapshot.isStaleFor(this, expectedEpoch, expectedUserId)) {
      return null;
    }
    return _AccountSnapshot.capture(this);
  }

  Future<bool> _toggleStickerRemoteAware(String stickerId) async {
    if (stickerId.isEmpty) return false;
    final snap = await _loadSnapshotForOperation();
    if (snap == null) return false;
    final cache = List<EmojiFavoriteItem>.from(snap.items);
    final index = cache.indexWhere(
      (entry) =>
          entry.type == EmojiFavoriteType.sticker &&
          entry.stickerId == stickerId,
    );
    if (index >= 0) {
      final existing = cache[index];
      if (repository != null && existing.serverId != null) {
        await repository!.delete(existing.serverId!);
        if (snap.stale) return false;
      }
      cache.removeAt(index);
      await _commit(snap, cache);
      return false;
    }
    var item = EmojiFavoriteItem.sticker(stickerId);
    if (repository != null && snap.userId != null) {
      item = await repository!.createBuiltin(stickerId);
      if (snap.stale) return false;
    }
    cache.insert(0, item);
    _trimToMax(cache);
    await _commit(snap, cache);
    return true;
  }

  Future<bool> _toggleImageRemoteAware(String imageUrl) async {
    if (imageUrl.isEmpty) return false;
    final snap = await _loadSnapshotForOperation();
    if (snap == null) return false;
    final cache = List<EmojiFavoriteItem>.from(snap.items);
    final index = cache.indexWhere(
      (entry) =>
          entry.type == EmojiFavoriteType.image &&
          (entry.imageUrl == imageUrl || entry.thumbnailUrl == imageUrl),
    );
    if (index >= 0) {
      final existing = cache[index];
      if (repository != null && existing.serverId != null) {
        await repository!.delete(existing.serverId!);
        if (snap.stale) return false;
      }
      cache.removeAt(index);
      await _commit(snap, cache);
      return false;
    }
    var item = EmojiFavoriteItem.image(imageUrl);
    if (repository != null && snap.userId != null) {
      item = await repository!.createFromPublicImage(imageUrl);
      if (snap.stale) return false;
    }
    cache.insert(0, item);
    _trimToMax(cache);
    await _commit(snap, cache);
    return true;
  }

  Future<void> remove(EmojiFavoriteItem item) async {
    final snap = await _loadSnapshotForOperation();
    if (snap == null) return;
    final cache = List<EmojiFavoriteItem>.from(snap.items);
    if (repository != null && item.serverId != null) {
      await repository!.delete(item.serverId!);
      if (snap.stale) return;
    }
    final before = cache.length;
    cache.removeWhere((entry) => entry.key == item.key);
    if (cache.length == before) return;
    await _commit(snap, cache);
  }

  Future<bool> containsFile(int fileId) async {
    if (fileId <= 0) return false;
    return (await load()).any(
      (item) => item.type == EmojiFavoriteType.image && item.fileId == fileId,
    );
  }

  /// 添加收藏并置于列表首位，重复项不会产生第二条记录。
  Future<void> add(EmojiFavoriteItem item) async {
    if (item.key.endsWith(':')) return;
    final snap = await _loadSnapshotForOperation();
    if (snap == null) return;
    await _addWithSnapshot(snap, item);
  }

  /// 用调用方持有的账号快照原子地写入收藏，绝不在远程 await 之后重新捕获当前账号，
  /// 避免把旧账号（A）的结果写进新账号（B）的本地缓存。
  Future<void> _addWithSnapshot(
    _AccountSnapshot snap,
    EmojiFavoriteItem item,
  ) async {
    if (snap.stale) return;
    final cache = List<EmojiFavoriteItem>.from(snap.items);
    cache.removeWhere((entry) => entry.key == item.key);
    cache.insert(0, item);
    _trimToMax(cache);
    await _commit(snap, cache);
  }

  Future<EmojiFavoriteItem> addCustomFromUpload(int fileId) async {
    final snap = await _loadSnapshotForOperation();
    if (snap == null) {
      throw const EmojiFavoriteException(
        message: '账号已切换，请重试',
        code: 'account_switched',
      );
    }

    var item = EmojiFavoriteItem.custom(fileId: fileId);
    if (repository != null && snap.userId != null) {
      item = await repository!.createCustom(fileId);
      if (snap.stale) {
        throw const EmojiFavoriteException(
          message: '账号已切换，请重试',
          code: 'account_switched',
        );
      }
    }

    await _addWithSnapshot(snap, item);
    return item;
  }

  Future<EmojiFavoriteItem> addFromMessage(int messageId) async {
    if (repository == null || _userId == null) {
      throw const EmojiFavoriteException(
        message: '当前账号未连接收藏服务',
        code: 'emoji_service_unavailable',
      );
    }
    final snap = await _loadSnapshotForOperation();
    if (snap == null) {
      throw const EmojiFavoriteException(
        message: '账号已切换，请重试',
        code: 'account_switched',
      );
    }
    final item = await repository!.createFromMessage(messageId);
    if (snap.stale) {
      throw const EmojiFavoriteException(
        message: '账号已切换，请重试',
        code: 'account_switched',
      );
    }
    await _addWithSnapshot(snap, item);
    return item;
  }

  /// 删除失败时恢复到原始位置，用于撤销操作。
  Future<void> undo(EmojiFavoriteItem item, {int index = 0}) async {
    final snap = await _loadSnapshotForOperation();
    if (snap == null) return;
    final cache = List<EmojiFavoriteItem>.from(snap.items);
    var restored = item;
    if (repository != null && snap.userId != null) {
      if (item.type == EmojiFavoriteType.sticker &&
          item.stickerId?.isNotEmpty == true) {
        restored = await repository!.createBuiltin(item.stickerId!);
        if (snap.stale) return;
      } else if (item.fileId != null && item.fileId! > 0) {
        restored = await repository!.createCustom(item.fileId!);
        if (snap.stale) return;
      }
    }
    cache.removeWhere(
      (entry) => entry.key == item.key || entry.key == restored.key,
    );
    final target = index.clamp(0, cache.length).toInt();
    cache.insert(target, restored);
    _trimToMax(cache);
    await _commit(snap, cache);
  }

  /// 仅在账号未切换时把结果写回内存并按快照缓存键持久化。
  Future<void> _commit(
    _AccountSnapshot snap,
    List<EmojiFavoriteItem> items,
  ) async {
    if (snap.stale) return;
    _cache = List<EmojiFavoriteItem>.from(items);
    await _persist(snap.cacheKey, _cache!);
    notifyListeners();
  }

  Future<void> _persist(String cacheKey, List<EmojiFavoriteItem> items) async {
    final preferences = await _preferences;
    await preferences.setString(
      cacheKey,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  List<EmojiFavoriteItem> _dedupe(Iterable<EmojiFavoriteItem> values) {
    final result = <EmojiFavoriteItem>[];
    for (final item in values) {
      if (item.key.endsWith(':') ||
          result.any((entry) => entry.key == item.key)) {
        continue;
      }
      result.add(item);
    }
    return result;
  }

  void _trimToMax(List<EmojiFavoriteItem> cache) {
    if (cache.length > maxFavoriteCount) {
      cache.removeRange(maxFavoriteCount, cache.length);
    }
  }
}
