import 'package:dio/dio.dart';

import '../models/security_event.dart';

class AdminSecurityService {
  final Dio dio;

  const AdminSecurityService(this.dio);

  Future<SecurityOverview> loadOverview({String range = '24h'}) async {
    final response = await dio
        .get('/admin/security/overview', queryParameters: {'range': range});
    return SecurityOverview.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<List<SecurityEvent>> loadEvents({
    String severity = 'all',
    String status = 'all',
    int page = 1,
  }) async {
    final response = await dio.get('/admin/security/events', queryParameters: {
      'severity': severity,
      'status': status,
      'page': page,
      'limit': 50,
    });
    final data = Map<String, dynamic>.from(response.data as Map);
    final items = data['items'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((item) => SecurityEvent.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> resolve(int id, {String note = ''}) async {
    await dio.post('/admin/security/events/$id/resolve', data: {'note': note});
  }

  Future<void> markFalsePositive(int id, {String note = ''}) async {
    await dio.post('/admin/security/events/$id/false-positive',
        data: {'note': note});
  }

  Future<void> createBlock({
    required String sourceKey,
    required int durationMinutes,
    String routePrefix = '',
    String reason = '',
  }) async {
    await dio.post('/super/security/blocks', data: {
      'source_key': sourceKey,
      'duration_minutes': durationMinutes,
      'route_prefix': routePrefix,
      'reason': reason,
    });
  }
}
