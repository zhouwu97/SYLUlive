import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/canteen.dart';
import '../models/canteen_dish.dart';
import '../models/canteen_review.dart';

class CanteenRatingSubmitResult {
  final bool success;
  final String? errorCode;
  final String? errorMessage;
  final DateTime? remoteUpdatedAt;

  const CanteenRatingSubmitResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
    this.remoteUpdatedAt,
  });
}

class CanteenMutationResult {
  final bool success;
  final String? errorCode;
  final String? errorMessage;
  final bool alreadyDeleted;

  const CanteenMutationResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
    this.alreadyDeleted = false,
  });
}

class CanteenProvider with ChangeNotifier {
  final Dio _dio;

  List<Canteen> _canteens = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<Canteen> get canteens => _canteens;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  CanteenProvider(this._dio);

  // ── 模块可选项（服务端 /canteens/meta 下发）────────────────────────
  // 旧服务端没有该接口或请求失败时，回退到内置默认值，不影响提交和筛选。
  static const List<String> defaultLocationAreas = ['一食堂', '二食堂'];
  static const List<String> defaultLocationFloors = ['一楼', '二楼'];

  List<String> _locationAreas = defaultLocationAreas;
  List<String> _locationFloors = defaultLocationFloors;
  List<({String key, String label})> _reviewTags = const [];
  Future<void>? _metaFuture;

  List<String> get locationAreas => _locationAreas;
  List<String> get locationFloors => _locationFloors;

  /// 体验标签默认值，与服务端 canteenTagOrder 一致；服务端下发后以下发为准。
  static const List<({String key, String label})> defaultReviewTags = [
    (key: 'taste_good', label: '味道不错'),
    (key: 'portion_enough', label: '分量足'),
    (key: 'price_fair', label: '价格合适'),
    (key: 'serving_fast', label: '出餐快'),
    (key: 'queue_long', label: '排队久'),
    (key: 'recommended_window', label: '推荐窗口'),
    (key: 'clean', label: '卫生干净'),
    (key: 'service_warm', label: '服务热情'),
    (key: 'environment_clean', label: '环境整洁'),
    (key: 'good_value', label: '性价比高'),
  ];

  /// 体验标签：优先用服务端下发的列表，旧服务端或尚未加载时用默认值。
  List<({String key, String label})> get reviewTags =>
      _reviewTags.isEmpty ? defaultReviewTags : _reviewTags;

  /// 加载一次可选项；失败后允许下次调用重试。
  Future<void> loadMeta() {
    return _metaFuture ??= _loadMetaInternal().then((ok) {
      if (!ok) _metaFuture = null;
    });
  }

  Future<bool> _loadMetaInternal() async {
    try {
      final response = await _dio.get('/canteens/meta');
      final data = response.data;
      if (response.statusCode != 200 || data is! Map) return false;
      List<String> strings(dynamic raw) => raw is List
          ? raw
              .map((item) => item?.toString().trim() ?? '')
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
          : const [];
      final areas = strings(data['location_areas']);
      final floors = strings(data['location_floors']);
      final tags = data['review_tags'] is List
          ? (data['review_tags'] as List)
              .whereType<Map>()
              .map((tag) => (
                    key: tag['key']?.toString() ?? '',
                    label: tag['label']?.toString() ?? '',
                  ))
              .where((tag) => tag.key.isNotEmpty && tag.label.isNotEmpty)
              .toList(growable: false)
          : const <({String key, String label})>[];
      if (areas.isNotEmpty) _locationAreas = areas;
      if (floors.isNotEmpty) _locationFloors = floors;
      _reviewTags = tags;
      notifyListeners();
      return true;
    } on DioException catch (e) {
      debugPrint('Error loading canteen meta: $e');
      return false;
    }
  }

  // ── 收藏（我常去）──────────────────────────────────────────────
  List<Canteen> _favorites = const [];
  int? _favoritesOwnerId;

  /// 只返回属于 [userId] 的收藏；切换账号后上一个账号的收藏不会出现。
  List<Canteen> favoritesFor(int? userId) =>
      userId != null && userId == _favoritesOwnerId ? _favorites : const [];

  /// 拉取 [userId] 收藏的商家；失败时保留上次结果，返回 false。
  Future<bool> loadFavorites({required int userId}) async {
    try {
      final response = await _dio.get('/user/canteen-favorites');
      final items =
          response.data is Map ? (response.data as Map)['items'] : null;
      if (response.statusCode == 200 && items is List) {
        _favoritesOwnerId = userId;
        _favorites = items
            .whereType<Map>()
            .map((item) => Canteen.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false);
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      debugPrint('Error loading canteen favorites: $e');
    }
    return false;
  }

  /// 退出登录或切换账号时清空，避免上一个账号的收藏出现在首页。
  void clearFavorites() {
    if (_favorites.isEmpty && _favoritesOwnerId == null) return;
    _favorites = const [];
    _favoritesOwnerId = null;
    notifyListeners();
  }

  /// 收藏或取消收藏；成功后同步本地列表。
  Future<bool> setFavorite(int canteenId, bool favorite) async {
    _errorMessage = null;
    try {
      final path = '/user/canteen-favorites/$canteenId';
      final response =
          favorite ? await _dio.put(path) : await _dio.delete(path);
      if (response.statusCode == 200) {
        if (!favorite) {
          _favorites = _favorites
              .where((canteen) => canteen.id != canteenId)
              .toList(growable: false);
          notifyListeners();
        }
        return true;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return false;
  }

  /// 管理员修改商家名称与位置；只发送传入的字段。
  Future<bool> adminUpdateCanteen(
    int canteenId, {
    String? name,
    String? locationArea,
    String? locationFloor,
  }) async {
    _errorMessage = null;
    try {
      final response = await _dio.patch('/canteens/$canteenId', data: {
        if (name != null) 'name': name,
        if (locationArea != null) 'location_area': locationArea,
        if (locationFloor != null) 'location_floor': locationFloor,
      });
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      return false;
    }
  }

  Future<void>? _loadFuture;

  Future<void> loadCanteens() {
    if (_loadFuture != null) return _loadFuture!;
    _loadFuture = _loadCanteensInternal().whenComplete(() {
      _loadFuture = null;
    });
    return _loadFuture!;
  }

  Future<void> _loadCanteensInternal() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _dio.get('/canteens');
      if (response.statusCode == 200) {
        final List<dynamic> data = response.data;
        _canteens = data.map((json) => Canteen.fromJson(json)).toList();
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading canteens: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> searchCanteensAndDishes(String query) async {
    try {
      final response = await _dio.get(
        '/canteens/search',
        queryParameters: {'q': query.trim()},
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error searching canteens and dishes: $e');
    }
    return null;
  }

  Future<bool> addCanteen(
    String name,
    String image, {
    String locationArea = '',
    String locationFloor = '',
  }) async {
    _errorMessage = null;
    try {
      final response = await _dio.post(
        '/canteens',
        data: {
          'name': name,
          'image': image,
          if (locationArea.isNotEmpty) 'location_area': locationArea,
          if (locationFloor.isNotEmpty) 'location_floor': locationFloor,
        },
      );
      return response.statusCode == 201;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error adding canteen: $e');
      return false;
    }
  }

  /// 详情页首屏只取前 [reviewPageSize] 条混合评价（compact 模式），
  /// 其余通过 [loadDisplayReviews] 分页拉取；旧服务端会忽略这两个参数并返回全部。
  static const int reviewPageSize = 20;

  Future<Map<String, dynamic>> loadCanteenDetail(
    int id, {
    String reviewSort = 'best',
    String reviewFilter = 'all',
  }) async {
    final queryParameters = {
      'review_sort': reviewSort,
      'review_filter': reviewFilter,
      'compact': '1',
      'review_limit': '$reviewPageSize',
    };
    try {
      final response = await _dio.get(
        '/canteens/$id/detail',
        queryParameters: queryParameters,
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      // 新路由上线前的旧服务端仍可能只暴露 /canteens/:id，保留一次兼容回退。
      if (e.response?.statusCode != 404) {
        _errorMessage = _parseError(e);
        debugPrint('Error loading canteen detail: $e');
        return {};
      }
    }
    try {
      final response = await _dio.get(
        '/canteens/$id',
        queryParameters: queryParameters,
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading canteen detail: $e');
    }
    return {};
  }

  /// 分页读取详情页混合评价流。返回 null 表示失败；[unsupported] 为 true 表示
  /// 服务端还没有这个接口（旧版本），调用方应回退到重新加载整页详情。
  Future<
      ({
        List<Map<String, dynamic>> items,
        int total,
        bool hasMore,
        bool unsupported
      })?> loadDisplayReviews(
    int canteenId, {
    required String sort,
    required String filter,
    int offset = 0,
    int limit = reviewPageSize,
  }) async {
    _errorMessage = null;
    try {
      final response = await _dio.get(
        '/canteens/$canteenId/display-reviews',
        queryParameters: {
          'sort': sort,
          'filter': filter,
          'offset': offset,
          'limit': limit,
        },
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['items'] is List) {
        final items = (data['items'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        return (
          items: items,
          total: (data['total'] as num?)?.toInt() ?? offset + items.length,
          hasMore: data['has_more'] == true,
          unsupported: false,
        );
      }
      _errorMessage = '评价加载失败，请重试';
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return (
          items: const <Map<String, dynamic>>[],
          total: 0,
          hasMore: false,
          unsupported: true,
        );
      }
      _errorMessage = _parseError(e);
    }
    return null;
  }

  Future<Map<String, dynamic>?> voteRating({
    required int ratingId,
    required String vote,
  }) async {
    try {
      final response = await _dio.put(
        '/canteens/ratings/$ratingId/vote',
        data: {'vote': vote},
      );
      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error voting canteen rating: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> voteReview({
    required int reviewId,
    required String vote,
  }) async {
    try {
      final response = await _dio.put(
        '/canteens/reviews/$reviewId/vote',
        data: {'vote': vote},
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error voting canteen review: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> updateCanteenImage(
      int id, String imageUrl) async {
    try {
      final response = await _dio.put(
        '/canteens/$id/image',
        data: {'image': imageUrl},
      );
      if (response.statusCode == 200) {
        return response.data['canteen'] as Map<String, dynamic>?;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error updating canteen image: $e');
    }
    return null;
  }

  Future<bool> deleteCanteen(int id) async {
    try {
      final response = await _dio.delete('/canteens/$id');
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error deleting canteen: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> getDisplayTags(int id) async {
    final response = await _dio.get('/canteens/$id/display-tags');
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> updateDisplayTags(
      int id, String area, String floor, List<String>? tags) async {
    await _dio.put('/canteens/$id/display-tags', data: {
      'location_area': area,
      'location_floor': floor,
      'tags': tags,
    });
  }

  Future<Map<String, dynamic>?> offlineCanteen(int id,
      {String reason = ''}) async {
    try {
      final response = await _dio.post(
        '/canteens/$id/offline',
        data: {'reason': reason.trim()},
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error offlining canteen: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> onlineCanteen(int id) async {
    try {
      final response = await _dio.post('/canteens/$id/online');
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error onlining canteen: $e');
    }
    return null;
  }

  Future<CanteenRatingSubmitResult> rateCanteen(
    int id, {
    required int star,
    required String comment,
    List<String> images = const [],
    List<String> tags = const [],
    List<String> recommendedDishes = const [],
    DateTime? baseUpdatedAt,
  }) async {
    errorCode = null;
    try {
      final payload = <String, dynamic>{
        'star': star,
        'comment': comment,
        'images': json.encode(images),
        'tags': tags,
        'recommended_dishes': recommendedDishes,
      };
      if (baseUpdatedAt != null) {
        payload['base_updated_at'] = baseUpdatedAt.toUtc().toIso8601String();
      }
      final response = await _dio.post(
        '/canteens/$id/rate',
        data: payload,
      );
      final ok = response.statusCode == 200 || response.statusCode == 201;
      return CanteenRatingSubmitResult(success: ok);
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      String? code;
      DateTime? remoteTime;
      if (e.response?.data is Map) {
        code = e.response!.data['code']?.toString();
        errorCode = code;
        final rawRemote = e.response!.data['remote_updated_at']?.toString();
        if (rawRemote != null) {
          remoteTime = DateTime.tryParse(rawRemote);
        }
      }
      debugPrint('Error rating canteen: $e');
      return CanteenRatingSubmitResult(
        success: false,
        errorCode: code,
        errorMessage: _errorMessage,
        remoteUpdatedAt: remoteTime,
      );
    }
  }

  /// V2 店铺评价入口。创建评价必须写入 ReviewEvent，不能回退到旧摘要 /rate。
  Future<CanteenRatingSubmitResult> submitReview(
    int id, {
    required CanteenReviewDimensions dimensions,
    required String comment,
    List<String> images = const [],
    List<String> tags = const [],
    List<int> dishIds = const [],
    List<String> dishNames = const [],
    List<CanteenDishReviewInput> dishReviews = const [],
    List<CanteenDishReviewInput> dishes = const [],
    String? idempotencyKey,
    DateTime? baseUpdatedAt,
  }) async {
    errorCode = null;
    final payload = <String, dynamic>{
      ...dimensions.toJson(),
      'comment': comment,
      'images': images,
      'tags': tags,
      if (dishIds.isNotEmpty) 'dish_ids': dishIds,
      if (dishNames.isNotEmpty) 'dish_names': dishNames,
      if (dishReviews.isNotEmpty)
        'dish_reviews': dishReviews.map((dish) => dish.toJson()).toList(),
      if (dishes.isNotEmpty)
        'dishes': dishes.map((dish) => dish.toJson()).toList(),
      if (baseUpdatedAt != null)
        'base_updated_at': baseUpdatedAt.toUtc().toIso8601String(),
    };
    try {
      final response = await _dio.post(
        '/canteens/$id/reviews',
        data: payload,
        options: idempotencyKey == null || idempotencyKey.trim().isEmpty
            ? null
            : Options(headers: {'Idempotency-Key': idempotencyKey.trim()}),
      );
      final data = response.data;
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          data is Map &&
          data['review'] != null) {
        return CanteenRatingSubmitResult(
          success: true,
          remoteUpdatedAt: DateTime.tryParse(
            (data['review'] as Map)['updated_at']?.toString() ?? '',
          ),
        );
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      final data = e.response?.data;
      if (data is Map) {
        errorCode = data['code']?.toString();
      }
      return CanteenRatingSubmitResult(
        success: false,
        errorCode: errorCode,
        errorMessage: _errorMessage,
      );
    }
    return const CanteenRatingSubmitResult(
      success: false,
      errorMessage: '评价服务返回异常',
    );
  }

  Future<CanteenRatingSubmitResult> updateReview(
    int reviewId, {
    required CanteenReviewDimensions dimensions,
    required String comment,
    List<String> images = const [],
    List<String> tags = const [],
    List<int> dishIds = const [],
    List<String> dishNames = const [],
    List<CanteenDishReviewInput> dishReviews = const [],
    List<CanteenDishReviewInput> dishes = const [],
    String? idempotencyKey,
    DateTime? baseUpdatedAt,
  }) async {
    errorCode = null;
    try {
      final response = await _dio.patch(
        '/canteens/reviews/$reviewId',
        data: {
          ...dimensions.toJson(),
          'comment': comment,
          'images': images,
          'tags': tags,
          if (dishIds.isNotEmpty) 'dish_ids': dishIds,
          if (dishNames.isNotEmpty) 'dish_names': dishNames,
          if (dishReviews.isNotEmpty)
            'dish_reviews': dishReviews.map((dish) => dish.toJson()).toList(),
          if (dishes.isNotEmpty)
            'dishes': dishes.map((dish) => dish.toJson()).toList(),
          if (baseUpdatedAt != null)
            'base_updated_at': baseUpdatedAt.toUtc().toIso8601String(),
        },
        options: idempotencyKey == null || idempotencyKey.trim().isEmpty
            ? null
            : Options(headers: {'Idempotency-Key': idempotencyKey.trim()}),
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map &&
          response.data['review'] != null) {
        return CanteenRatingSubmitResult(
          success: true,
          remoteUpdatedAt: DateTime.tryParse(
            (response.data['review'] as Map)['updated_at']?.toString() ?? '',
          ),
        );
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        final data = e.response!.data as Map;
        errorCode = data['code']?.toString();
        final rawRemote = data['remote_updated_at']?.toString();
        final remoteUpdatedAt =
            rawRemote == null ? null : DateTime.tryParse(rawRemote);
        return CanteenRatingSubmitResult(
          success: false,
          errorCode: errorCode,
          errorMessage: _errorMessage,
          remoteUpdatedAt: remoteUpdatedAt,
        );
      }
      return CanteenRatingSubmitResult(
        success: false,
        errorCode: errorCode,
        errorMessage: _errorMessage,
      );
    }
    return const CanteenRatingSubmitResult(
      success: false,
      errorMessage: '评价服务返回异常',
    );
  }

  /// 删除自己的 V2 或 Legacy 评价；source 用于区分两个自增 ID 空间。
  Future<CanteenMutationResult> deleteReview({
    required int id,
    required String source,
  }) async {
    errorCode = null;
    final path =
        source == 'legacy' ? '/canteens/ratings/$id' : '/canteens/reviews/$id';
    try {
      final response = await _dio.delete(path);
      final data = response.data;
      if (response.statusCode == 200) {
        return CanteenMutationResult(
          success: true,
          alreadyDeleted: data is Map && data['already_deleted'] == true,
        );
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
      return CanteenMutationResult(
        success: false,
        errorCode: errorCode,
        errorMessage: _errorMessage,
      );
    }
    return const CanteenMutationResult(
      success: false,
      errorMessage: '删除评价服务返回异常',
    );
  }

  Future<List<CanteenReviewEvent>?> loadReviews(
    int canteenId, {
    bool history = false,
    int? userId,
  }) async {
    try {
      final path = userId == null
          ? '/canteens/$canteenId/reviews'
          : '/canteens/$canteenId/reviews/history/$userId';
      final response = await _dio.get(
        path,
        queryParameters: history ? {'history': 1} : null,
      );
      if (response.statusCode == 200 && response.data is Map) {
        final items = response.data['items'];
        if (items is List) {
          return items
              .whereType<Map>()
              .map((item) => CanteenReviewEvent.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        }
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return null;
  }

  /// 本人食堂记录与列表使用同一接口，跨页统计时绑定调用方的账号代次。
  Future<int?> countMyCanteenReviews(
      {required bool Function() isCurrent}) async {
    final cursors = <String>{};
    final records = <String>{};
    String? cursor;
    try {
      while (isCurrent()) {
        final page = await loadMyCanteenReviews(limit: 50, cursor: cursor);
        if (!isCurrent() || page == null) return null;
        for (final item in page.items) {
          final legacy = item.source == 'legacy';
          records.add(
              '${legacy ? 'legacy' : 'v2'}:${legacy ? item.legacyRatingId ?? item.id : item.id}');
        }
        if (!page.hasMore) return records.length;
        final next = page.nextCursor;
        if (next == null || next.isEmpty || !cursors.add(next)) return null;
        cursor = next;
      }
    } catch (_) {
      // 无法确认完整数量时保持未知，不将半页结果或失败伪装成零。
    }
    return null;
  }

  Future<CanteenReviewPage?> loadMyCanteenReviews({
    int limit = 20,
    String? cursor,
  }) async {
    try {
      final response = await _dio.get(
        '/user/canteen-reviews',
        queryParameters: {
          'limit': limit,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      if (response.statusCode == 200 && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final rawItems = data['items'];
        final items = rawItems is List
            ? rawItems
                .whereType<Map>()
                .map((item) => CanteenReviewEvent.fromJson(
                      Map<String, dynamic>.from(item),
                    ))
                .toList(growable: false)
            : const <CanteenReviewEvent>[];
        return CanteenReviewPage(
          items: items,
          nextCursor: data['next_cursor']?.toString(),
          hasMore: data['has_more'] == true || data['next_cursor'] != null,
        );
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
    }
    return null;
  }

  /// 从服务端读取完整评价编辑上下文，供所有编辑入口共用。
  Future<Map<String, dynamic>?> loadReviewEditContext(int reviewId) async {
    try {
      final response = await _dio.get(
        '/canteens/reviews/$reviewId/edit-context',
      );
      if (response.statusCode == 200 && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final review = data['review'];
        return review is Map ? Map<String, dynamic>.from(review) : data;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> loadMyCanteenContributions() async {
    _errorMessage = null;
    try {
      final response = await _dio.get('/user/canteen-contributions');
      if (response.statusCode == 200 && response.data is Map) {
        final raw = (response.data as Map)['items'];
        return raw is List
            ? raw
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
            : const [];
      }
      _errorMessage = '贡献记录加载失败，请重试';
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return null;
  }

  Future<List<CanteenDishSuggestion>?> suggestDishes(
    int canteenId,
    String query,
  ) async {
    try {
      final response = await _dio.get(
        '/canteens/$canteenId/dish-suggestions',
        queryParameters: {'q': query},
      );
      if (response.statusCode == 200 && response.data is Map) {
        final items = response.data['items'];
        if (items is List) {
          return items
              .whereType<Map>()
              .map((item) => CanteenDishSuggestion.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        }
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return null;
  }

  Future<Map<String, dynamic>?> adminGetDishPhotoDetail(int photoId) async {
    try {
      final response = await _dio.get('/canteens/dish-photos/$photoId');
      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Error getting dish photo detail: $e');
    }
    return null;
  }

  String? _dishesErrorMessage;
  String? get dishesErrorMessage => _dishesErrorMessage;

  String _parseError(DioException e) {
    if (e.response?.data is Map) {
      final data = e.response!.data as Map;
      // 服务端统一错误格式为 {code, message, request_id}，旧接口仍是 {error}。
      final message = data['message'] ?? data['error'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString();
      }
    }
    final status = e.response?.statusCode;
    if (status == 404) {
      return '菜品服务暂不可用';
    }
    if (status != null && status >= 500) {
      return '菜品加载失败，请稍后重试';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return '网络连接失败，请检查网络后重试';
    }
    return '加载异常，请重试';
  }

  // ── 菜品图库 ──────────────────────────────────────────────────────

  /// 加载菜品图鉴。
  /// 返回语义：
  /// - `[]`：请求成功，确实没有菜品
  /// - `null`：请求失败（网络 / 5xx / 超时），调用方不应把统计刷成 0
  Future<List<CanteenDish>?> loadDishes(int canteenId) async {
    _dishesErrorMessage = null;
    try {
      final response = await _dio.get('/canteens/$canteenId/dishes');
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .map((json) => CanteenDish.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      _dishesErrorMessage = '数据格式异常';
      return null;
    } on DioException catch (e) {
      _dishesErrorMessage = _parseError(e);
      debugPrint('Error loading dishes: $e');
      return null;
    } catch (e) {
      _dishesErrorMessage = '数据解析异常';
      return null;
    }
  }

  Future<Map<String, dynamic>?> loadDishDetail(
    int canteenId,
    int dishId,
  ) async {
    try {
      final response = await _dio.get('/canteens/$canteenId/dishes/$dishId');
      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading dish detail: $e');
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> loadDishReviews(int dishId) async {
    try {
      final response = await _dio.get('/canteens/dishes/$dishId/reviews');
      if (response.statusCode == 200 && response.data is Map) {
        final items = response.data['items'];
        if (items is List) {
          return items
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
        }
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading dish reviews: $e');
    }
    return null;
  }

  /// 分页读取菜品评价（服务端按同学去重、时间倒序）。返回 null 表示请求失败。
  Future<({List<Map<String, dynamic>> items, int total, bool hasMore})?>
      loadDishReviewPage(int dishId, {int offset = 0, int limit = 20}) async {
    _errorMessage = null;
    try {
      final response = await _dio.get(
        '/canteens/dishes/$dishId/reviews',
        queryParameters: {'offset': offset, 'limit': limit},
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['items'] is List) {
        final items = (data['items'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        final total = (data['total'] as num?)?.toInt() ?? offset + items.length;
        // 旧服务端不认识分页参数会一次返回全部，此时没有 has_more。
        final hasMore = data['has_more'] == true;
        return (items: items, total: total, hasMore: hasMore);
      }
      _errorMessage = '评价加载失败，请重试';
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return null;
  }

  /// 管理员把一张实拍设为菜品封面。
  Future<bool> adminSetDishPhotoCover(int photoId) async {
    _errorMessage = null;
    try {
      final response = await _dio.post('/canteens/dish-photos/$photoId/cover');
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      return false;
    }
  }

  /// 管理端操作通过 [errorCode] 暴露服务端业务错误码。
  String? errorCode;

  /// 管理员待审核食堂提交列表。返回 null 表示请求失败；
  /// 成功但无数据时返回空列表。
  Future<List<Map<String, dynamic>>?> adminListPendingCanteens() async {
    try {
      final response = await _dio.get('/canteens/pending');
      if (response.statusCode == 200) {
        final items = (response.data as Map<String, dynamic>)['items'];
        if (items is List) {
          return items.cast<Map<String, dynamic>>();
        }
        return const [];
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error listing pending canteens: $e');
    }
    return null;
  }

  /// 审核通过待审食堂，使其进入公开列表。
  Future<String?> adminApproveCanteen(int canteenId) async {
    errorCode = null;
    try {
      final response = await _dio.post('/canteens/$canteenId/approve');
      if (response.statusCode == 200) {
        return '审核已通过';
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
      debugPrint('Error approving canteen: $e');
    }
    return null;
  }

  /// 驳回待审食堂：提交记录保留给提交人查看原因，并退出待审列表。reason 可为空。
  Future<bool> adminRejectCanteen(int canteenId, {String reason = ''}) async {
    try {
      final response = await _dio.delete(
        '/canteens/$canteenId/pending',
        data: {'reason': reason},
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error rejecting canteen: $e');
      return false;
    }
  }

  /// 管理端菜品列表：包含上架和已隐藏的菜（已合并的菜只作为别名存在，不返回）。
  /// 返回 null 表示请求失败，原因见 [errorMessage]。
  Future<List<AdminCanteenDish>?> adminListDishes(int canteenId) async {
    _errorMessage = null;
    try {
      final response = await _dio.get('/canteens/$canteenId/admin-dishes');
      final items =
          response.data is Map ? (response.data as Map)['items'] : null;
      if (response.statusCode == 200 && items is List) {
        return items
            .whereType<Map>()
            .map((item) =>
                AdminCanteenDish.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      }
      _errorMessage = '菜品列表加载失败，请重试';
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    return null;
  }

  /// 将管理端识别出的疑似重复菜品合并到指定实体。
  Future<bool> adminMergeDish(int dishId, int targetDishId) async {
    _errorMessage = null;
    try {
      final response = await _dio.post(
        '/canteens/dishes/$dishId/merge',
        data: {'target_dish_id': targetDishId},
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error merging canteen dish: $e');
      return false;
    }
  }

  Future<bool> adminArchiveDishPhoto(int photoId) async {
    try {
      final response =
          await _dio.post('/canteens/dish-photos/$photoId/archive');
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error archiving dish photo: $e');
      return false;
    }
  }

  Future<bool> adminUpdateDish(
    int dishId, {
    String? name,
    String? status,
  }) async {
    _errorMessage = null;
    try {
      final response = await _dio.patch(
        '/canteens/dishes/$dishId',
        data: {
          if (name != null) 'name': name,
          if (status != null) 'status': status,
        },
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error updating dish: $e');
      return false;
    }
  }
}
