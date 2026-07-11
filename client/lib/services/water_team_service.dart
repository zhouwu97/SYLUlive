import 'package:dio/dio.dart';

import '../models/post.dart';
import '../models/water_team.dart';

/// 组队招募接口封装。
class WaterTeamService {
  final Dio _dio;

  WaterTeamService(this._dio);

  Future<WaterTeamApplication> apply({
    required int recruitmentId,
    required String message,
    String availability = '',
  }) async {
    final response = await _dio.post(
      '/water/team/recruitments/$recruitmentId/apply',
      data: {'message': message, 'availability': availability},
    );
    return WaterTeamApplication.fromJson(_mapData(response.data));
  }

  Future<void> cancel({required int applicationId}) async {
    await _dio.post('/water/team/applications/$applicationId/cancel');
  }

  Future<List<WaterTeamApplication>> getMyApplications() async {
    final response = await _dio.get('/water/team/my_applications');
    return _parseList(response.data);
  }

  Future<List<WaterTeamApplication>> getRecruitmentApplications({
    required int recruitmentId,
  }) async {
    final response = await _dio.get(
      '/water/team/recruitments/$recruitmentId/applications',
    );
    return _parseList(response.data);
  }

  Future<void> accept({required int applicationId, String reply = ''}) async {
    await _review(applicationId, 'accept', reply);
  }

  Future<void> reject({required int applicationId, String reply = ''}) async {
    await _review(applicationId, 'reject', reply);
  }

  Future<void> _review(int applicationId, String action, String reply) async {
    await _dio.post(
      '/water/team/applications/$applicationId/$action',
      data: {'reply': reply},
    );
  }

  Future<Post> updateRecruitmentStatus({
    required int recruitmentId,
    required String status,
  }) async {
    final response = await _dio.patch(
      '/water/team/recruitments/$recruitmentId/status',
      data: {'status': status},
    );
    final data = _mapData(response.data);
    return Post.fromJson(
        (data['post'] as Map?)?.cast<String, dynamic>() ?? data);
  }

  static Map<String, dynamic> _mapData(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  static List<WaterTeamApplication> _parseList(dynamic value) {
    final data = value is Map ? value['applications'] ?? value['data'] : value;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) =>
            WaterTeamApplication.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }
}
