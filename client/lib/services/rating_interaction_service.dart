import 'package:dio/dio.dart';

class RatingInteractionService {
  final Dio _dio;

  RatingInteractionService(this._dio);

  Future<Map<String, dynamic>?> voteTeacherRating(
      int ratingId, String vote) async {
    try {
      final res = await _dio.put(
        '/teachers/ratings/$ratingId/vote',
        data: {'vote': vote},
      );
      return res.data as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> voteMajorRating(
      int ratingId, String vote) async {
    try {
      final res = await _dio.put(
        '/majors/ratings/$ratingId/vote',
        data: {'vote': vote},
      );
      return res.data as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  Future<bool> reportRating({
    required String targetType,
    required int targetId,
    required String reasonCode,
    required String reason,
  }) async {
    try {
      final response = await _dio.post('/reports', data: {
        'target_type': targetType,
        'target_id': targetId,
        'reason_code': reasonCode,
        'reason': reason,
      });
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
