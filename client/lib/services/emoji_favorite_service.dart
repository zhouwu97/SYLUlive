import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/contracts/preferences_store.dart';

enum EmojiFavoriteType { sticker, image }

class EmojiFavoriteItem {
  const EmojiFavoriteItem._({
    required this.type,
    this.stickerId,
    this.imageUrl,
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

  final EmojiFavoriteType type;
  final String? stickerId;
  final String? imageUrl;

  String get key => switch (type) {
        EmojiFavoriteType.sticker => 'sticker:${stickerId ?? ''}',
        EmojiFavoriteType.image => 'image:${imageUrl ?? ''}',
      };

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (stickerId != null) 'sticker_id': stickerId,
        if (imageUrl != null) 'image_url': imageUrl,
      };

  static EmojiFavoriteItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = value['type']?.toString();
    if (type == EmojiFavoriteType.sticker.name) {
      final stickerId = value['sticker_id']?.toString().trim();
      if (stickerId?.isNotEmpty == true) {
        return EmojiFavoriteItem.sticker(stickerId!);
      }
    }
    if (type == EmojiFavoriteType.image.name) {
      final imageUrl = value['image_url']?.toString().trim();
      if (imageUrl?.isNotEmpty == true) {
        return EmojiFavoriteItem.image(imageUrl!);
      }
    }
    return null;
  }
}

/// 表情收藏存储。
///
/// 收藏仅保存表情 ID 或服务端图片地址，不复制原图，避免偏好存储膨胀。
class EmojiFavoriteService extends ChangeNotifier {
  EmojiFavoriteService({
    Future<AppPreferencesStore> Function()? preferencesLoader,
  }) : _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

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
  Future<AppPreferencesStore>? _loadingPreferences;
  List<EmojiFavoriteItem>? _cache;

  Future<AppPreferencesStore> get _preferences =>
      _loadingPreferences ??= _preferencesLoader();

  Future<List<EmojiFavoriteItem>> load() async {
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);

    final preferences = await _preferences;
    final raw = preferences.getString(storageKey);
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

  Future<void> _persist() async {
    final preferences = await _preferences;
    await preferences.setString(
      storageKey,
      jsonEncode(_cache!.map((item) => item.toJson()).toList()),
    );
  }
}
