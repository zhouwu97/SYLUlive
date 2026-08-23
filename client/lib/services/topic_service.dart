import 'package:dio/dio.dart';

import '../models/topic.dart';

class TopicService {
  final Dio _dio;

  const TopicService(this._dio);

  Future<List<Topic>> search({
    String query = '',
    String? section,
    int limit = 20,
  }) async {
    final response = await _dio.get(
      '/topics/search',
      queryParameters: {
        'q': query.trim(),
        if (section != null && section.trim().isNotEmpty) 'section': section,
        'limit': limit,
      },
    );
    return _parse(response.data);
  }

  Future<List<Topic>> recommend({
    String query = '',
    String? section,
    int limit = 8,
  }) async {
    final response = await _dio.get(
      '/topics/recommend',
      queryParameters: {
        'q': query.trim(),
        if (section != null && section.trim().isNotEmpty) 'section': section,
        'limit': limit,
      },
    );
    return _parse(response.data);
  }

  List<Topic> _parse(dynamic data) {
    if (data is! Map) return const [];
    final raw = data['topics'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Topic.fromJson(Map<String, dynamic>.from(item)))
        .where((topic) => topic.name.trim().isNotEmpty)
        .toList(growable: false);
  }
}
