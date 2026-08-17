import 'dart:convert';

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
    final isSticker = kind == 'builtin' || kind == EmojiFavoriteType.sticker.name;
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
    if ((imageUrl == null || imageUrl.isEmpty) && _asInt(value['file_id']) == null) {
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

  @visibleForTesting
  static void resetSharedInstanceForTesting() {
    _sharedInstance?.dispose();
    _sharedInstance = null;
  }

  static const String storageKey = 'emoji_favorites_v1';
  static const int maxFavoriteCount = 80;

  final Future<AppPreferencesStore> Function() _preferencesLoader;
  /// 可选的云端仓储引用，保持服务与本地缓存解耦。
  final EmojiFavoriteRepository? repository;
  String? _userId;
  Future<AppPreferencesStore>? _loadingPreferences;
  List<EmojiFavoriteItem>? _cache;

  /// 当前账号的缓存键；未登录时继续读写旧 v1 键。
  String get accountStorageKey => _userId == null
      ? storageKey
      : 'emoji_favorites_cache_v2_${_userId!}';

  String? get userId => _userId;

  /// 账号切换时丢弃旧账号内存数据，避免跨账号短暂显示收藏。
  void switchUser(String? userId) {
    final normalized = userId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _userId) return;
    _userId = next;
    _cache = null;
    notifyListeners();
  }

  Future<AppPreferencesStore> get _preferences =>
      _loadingPreferences ??= _preferencesLoader();

  Future<List<EmojiFavoriteItem>> load([String? requestedUserId]) async {
    if (requestedUserId != null && requestedUserId.trim() != _userId) {
      switchUser(requestedUserId);
    }
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);

    final preferences = await _preferences;
    final raw = preferences.getString(accountStorageKey);
    final items = <EmojiFavoriteItem>[];
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
    _cache = items.take(maxFavoriteCount).toList(growable: true);
    return List.unmodifiable(_cache!);
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
          item.type == EmojiFavoriteType.image && item.imageUrl == normalized,
    );
  }

  Future<bool> toggleSticker(String stickerId) =>
      _toggle(EmojiFavoriteItem.sticker(stickerId.trim()));

  Future<bool> toggleImage(String imageUrl) =>
      _toggle(EmojiFavoriteItem.image(imageUrl.trim()));

  Future<bool> _toggle(EmojiFavoriteItem item) async {
    if (item.key.endsWith(':')) return false;
    await load();
    final index = _cache!.indexWhere((entry) => entry.key == item.key);
    final added = index < 0;
    if (added) {
      _cache!.insert(0, item);
      if (_cache!.length > maxFavoriteCount) {
        _cache!.removeRange(maxFavoriteCount, _cache!.length);
      }
    } else {
      _cache!.removeAt(index);
    }
    await _persist();
    notifyListeners();
    return added;
  }

  Future<void> remove(EmojiFavoriteItem item) async {
    await load();
    final before = _cache!.length;
    _cache!.removeWhere((entry) => entry.key == item.key);
    if (_cache!.length == before) return;
    await _persist();
    notifyListeners();
  }

  /// 添加收藏并置于列表首位，重复项不会产生第二条记录。
  Future<void> add(EmojiFavoriteItem item) async {
    if (item.key.endsWith(':')) return;
    await load();
    _cache!.removeWhere((entry) => entry.key == item.key);
    _cache!.insert(0, item);
    if (_cache!.length > maxFavoriteCount) {
      _cache!.removeRange(maxFavoriteCount, _cache!.length);
    }
    await _persist();
    notifyListeners();
  }

  /// 删除失败时恢复到原始位置，用于撤销操作。
  Future<void> undo(EmojiFavoriteItem item, {int index = 0}) async {
    await load();
    _cache!.removeWhere((entry) => entry.key == item.key);
    final target = index.clamp(0, _cache!.length).toInt();
    _cache!.insert(target, item);
    if (_cache!.length > maxFavoriteCount) {
      _cache!.removeRange(maxFavoriteCount, _cache!.length);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final preferences = await _preferences;
    await preferences.setString(
      accountStorageKey,
      jsonEncode(_cache!.map((item) => item.toJson()).toList()),
    );
  }
}
