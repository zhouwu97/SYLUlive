import 'package:dio/dio.dart';

import 'emoji_favorite_service.dart';

/// 服务端表情收藏列表及个人配额信息。
class EmojiFavoritePage {
  const EmojiFavoritePage({
    required this.items,
    required this.quotaUsed,
    required this.quotaLimit,
    required this.favoriteLimit,
  });

  final List<EmojiFavoriteItem> items;
  final int quotaUsed;
  final int quotaLimit;
  final int favoriteLimit;

  factory EmojiFavoritePage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <EmojiFavoriteItem>[];
    if (rawItems is List) {
      for (final value in rawItems.whereType<Map>()) {
        try {
          items.add(EmojiFavoriteItem.fromApiJson(
            Map<String, dynamic>.from(value),
          ));
        } on FormatException {
          // 单条记录损坏时保留其它收藏，下一次同步会修复本地缓存。
        }
      }
    }
    return EmojiFavoritePage(
      items: items,
      quotaUsed: _asInt(json['quota_used']) ?? 0,
      quotaLimit: _asInt(json['quota_limit']) ?? 50 * 1024 * 1024,
      favoriteLimit: _asInt(json['favorite_limit']) ?? 80,
    );
  }
}

/// 收藏接口返回的可读错误，保留服务端错误码和配额字段供 UI 展示。
class EmojiFavoriteException implements Exception {
  const EmojiFavoriteException({
    required this.message,
    this.code,
    this.quotaUsed,
    this.quotaLimit,
    this.statusCode,
  });

  final String message;
  final String? code;
  final int? quotaUsed;
  final int? quotaLimit;
  final int? statusCode;

  @override
  String toString() => 'EmojiFavoriteException(${code ?? 'unknown'}): $message';
}

/// 自定义表情收藏的 HTTP 仓储。
class EmojiFavoriteRepository {
  EmojiFavoriteRepository(this._dio);

  final Dio _dio;

  Future<EmojiFavoritePage> fetchFavorites() async {
    final response = await _request(() => _dio.get('/emoji/favorites'));
    return EmojiFavoritePage.fromJson(_map(response.data));
  }

  Future<EmojiFavoriteItem> createBuiltin(String stickerId) async {
    final response = await _request(
      () => _dio.post(
        '/emoji/favorites',
        data: <String, dynamic>{'kind': 'builtin', 'sticker_id': stickerId},
      ),
    );
    return _itemFromResponse(response.data);
  }

  Future<EmojiFavoriteItem> createCustom(int fileId) async {
    final response = await _request(
      () => _dio.post(
        '/emoji/favorites',
        data: <String, dynamic>{'kind': 'custom', 'file_id': fileId},
      ),
    );
    return _itemFromResponse(response.data);
  }

  Future<EmojiFavoriteItem> createFromMessage(int messageId) async {
    final response = await _request(
      () => _dio.post(
        '/emoji/favorites/from-message',
        data: <String, dynamic>{'message_id': messageId},
      ),
    );
    return _itemFromResponse(response.data);
  }

  Future<void> delete(int favoriteId) async {
    await _request(() => _dio.delete('/emoji/favorites/$favoriteId'));
  }

  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() operation,
  ) async {
    try {
      return await operation();
    } on DioException catch (error) {
      final data = error.response?.data;
      final payload = data is Map
          ? Map<String, dynamic>.from(data)
          : const <String, dynamic>{};
      throw EmojiFavoriteException(
        message: payload['message']?.toString() ??
            payload['error']?.toString() ??
            error.message ??
            '表情收藏请求失败',
        code: payload['code']?.toString(),
        quotaUsed: _asInt(payload['quota_used']),
        quotaLimit: _asInt(payload['quota_limit']),
        statusCode: error.response?.statusCode,
      );
    }
  }

  EmojiFavoriteItem _itemFromResponse(Object? data) {
    final map = _map(data);
    final nested = map['item'];
    if (nested is Map) {
      return EmojiFavoriteItem.fromApiJson({
        ...map,
        ...Map<String, dynamic>.from(nested),
      });
    }
    return EmojiFavoriteItem.fromApiJson(map);
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const FormatException('表情收藏响应格式无效');
  }
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
