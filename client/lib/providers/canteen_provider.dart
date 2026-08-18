import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/canteen.dart';
import '../models/canteen_dish.dart';

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

  Future<bool> rateCanteen(
    int id, {
    required int star,
    required String comment,
    List<String> images = const [],
    List<String> tags = const [],
    List<int> recommendedDishIds = const [],
  }) async {
    try {
      final response = await _dio.post(
        '/canteens/$id/rate',
        data: {
          'star': star,
          'comment': comment,
          'images': json.encode(images),
          'tags': tags,
          'recommended_dish_ids': recommendedDishIds,
        },
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error rating canteen: $e');
      return false;
    }
  }

  String _parseError(DioException e) {
    if (e.response?.data is Map && e.response?.data['error'] != null) {
      return e.response!.data['error'];
    }
    return '网络异常';
  }

  // ── 菜品图库 ──────────────────────────────────────────────────────

  /// 加载菜品图鉴。
  /// 返回语义：
  /// - `[]`：请求成功，确实没有菜品
  /// - `null`：请求失败（网络 / 5xx / 超时），调用方不应把统计刷成 0
  Future<List<CanteenDish>?> loadDishes(int canteenId) async {
    try {
      final response = await _dio.get('/canteens/$canteenId/dishes');
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .map((json) => CanteenDish.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return null;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      debugPrint('Error loading dishes: $e');
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
            '已提交审核';
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

  Future<String?> adminApproveDishPhoto(int photoId) async {
    errorCode = null;
    try {
      final response = await _dio.post('/canteens/dish-photos/$photoId/approve');
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
