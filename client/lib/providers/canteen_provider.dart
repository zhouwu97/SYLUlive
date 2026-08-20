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

class CanteenProvider with ChangeNotifier {
  final Dio _dio;

  List<Canteen> _canteens = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<Canteen> get canteens => _canteens;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  CanteenProvider(this._dio);

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

  Future<bool> addCanteen(String name, String image) async {
    try {
      final response = await _dio.post(
        '/canteens',
        data: {'name': name, 'image': image},
      );
      return response.statusCode == 201;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error adding canteen: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> loadCanteenDetail(
    int id, {
    String reviewSort = 'best',
    String reviewFilter = 'all',
  }) async {
    try {
      final response = await _dio.get(
        '/canteens/$id',
        queryParameters: {
          'review_sort': reviewSort,
          'review_filter': reviewFilter,
        },
      );
      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading canteen detail: $e');
    }
    return {};
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
      if (baseUpdatedAt != null)
        'base_updated_at': baseUpdatedAt.toUtc().toIso8601String(),
    };
    try {
      final response = await _dio.post('/canteens/$id/reviews', data: payload);
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
    return CanteenRatingSubmitResult(
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
    DateTime? baseUpdatedAt,
  }) async {
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
          if (baseUpdatedAt != null)
            'base_updated_at': baseUpdatedAt.toUtc().toIso8601String(),
        },
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map &&
          response.data['review'] != null) {
        return const CanteenRatingSubmitResult(success: true);
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
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
    if (e.response?.data is Map && e.response?.data['error'] != null) {
      return e.response!.data['error'].toString();
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
      _errorMessage = _dishesErrorMessage;
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

  /// 投稿菜品实拍。返回 null 表示网络错误；成功返回 message。
  /// 通过 [errorCode] 暴露服务端 code（如 dish_gallery_full）。
  String? errorCode;

  Future<String?> submitDishPhoto(
    int canteenId, {
    int? dishId,
    String? dishName,
    required int fileId,
  }) async {
    errorCode = null;
    try {
      final response = await _dio.post(
        '/canteens/$canteenId/dish-photos',
        data: {
          if (dishId != null) 'dish_id': dishId,
          if (dishName != null && dishName.trim().isNotEmpty)
            'dish_name': dishName.trim(),
          'file_id': fileId,
        },
      );
      if (response.statusCode == 201) {
        return (response.data as Map<String, dynamic>)['message']?.toString() ??
            '实拍已上传';
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
      debugPrint('Error submitting dish photo: $e');
    }
    return null;
  }

  /// V2 菜品投稿：进入审核队列，照片与新菜品均不会直接公开。
  Future<String?> submitDishSubmission(
    int canteenId, {
    int? dishId,
    String? dishName,
    required int fileId,
  }) async {
    errorCode = null;
    try {
      final response = await _dio.post(
        '/canteens/$canteenId/dish-submissions',
        data: {
          if (dishId != null) 'dish_id': dishId,
          if (dishName != null && dishName.trim().isNotEmpty)
            'dish_name': dishName.trim(),
          'file_id': fileId,
        },
      );
      if (response.statusCode == 201) {
        return (response.data as Map<String, dynamic>)['message']?.toString() ??
            '已提交审核';
      }
      // 旧服务端没有新路由时，保留旧提交路径作为兼容回退。
      if (response.statusCode == 404 ||
          response.statusCode == 405 ||
          response.data is Map && (response.data as Map).isEmpty) {
        return submitDishPhoto(
          canteenId,
          dishId: dishId,
          dishName: dishName,
          fileId: fileId,
        );
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
      if (e.response?.statusCode == 404 || e.response?.statusCode == 405) {
        return submitDishPhoto(
          canteenId,
          dishId: dishId,
          dishName: dishName,
          fileId: fileId,
        );
      }
    }
    return null;
  }

  /// 管理员待审核实拍列表。返回 null 表示请求失败；
  /// 成功但无数据时返回空列表（区分"失败"与"暂无"，避免失败伪装成空态）。
  Future<List<Map<String, dynamic>>?> adminListPendingDishPhotos() async {
    try {
      final response = await _dio.get('/canteens/dish-photos/pending');
      if (response.statusCode == 200) {
        final items = (response.data as Map<String, dynamic>)['items'];
        if (items is List) {
          return items.cast<Map<String, dynamic>>();
        }
        return const [];
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error listing pending dish photos: $e');
    }
    return null;
  }

  /// 将管理端识别出的疑似重复菜品合并到指定实体。
  Future<bool> adminMergeDish(int dishId, int targetDishId) async {
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

  Future<String?> adminApproveDishPhoto(int photoId) async {
    errorCode = null;
    try {
      final response =
          await _dio.post('/canteens/dish-photos/$photoId/approve');
      if (response.statusCode == 200) {
        return '已通过';
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      if (e.response?.data is Map) {
        errorCode = e.response!.data['code']?.toString();
      }
      debugPrint('Error approving dish photo: $e');
    }
    return null;
  }

  Future<bool> adminRejectDishPhoto(int photoId, String reason) async {
    try {
      final response = await _dio.post(
        '/canteens/dish-photos/$photoId/reject',
        data: {'reason': reason},
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error rejecting dish photo: $e');
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
