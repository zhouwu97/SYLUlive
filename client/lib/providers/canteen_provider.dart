import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/canteen.dart';

class CanteenProvider with ChangeNotifier {
  final Dio _dio;

  List<Canteen> _canteens = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<Canteen> get canteens => _canteens;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  CanteenProvider(this._dio);

  Future<void> loadCanteens() async {
    _isLoading = true;
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
    int id,
    int star,
    String comment,
  ) async {
    try {
      final response = await _dio.post(
        '/canteens/$id/rate',
        data: {'star': star, 'comment': comment, 'images': json.encode([])},
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
}
