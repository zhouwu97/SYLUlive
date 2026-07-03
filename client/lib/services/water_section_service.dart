import 'package:dio/dio.dart';
import '../models/water_section.dart';

/// 水帖版块读取服务。失败抛异常，由 Provider 决定 fallback。
class WaterSectionService {
  final Dio _dio;

  WaterSectionService(this._dio);

  Future<List<WaterSection>> fetchSections() async {
    final response = await _dio.get('/water/sections');
    if (response.statusCode == 200 && response.data != null) {
      final data = response.data;
      final list = data['sections'] as List<dynamic>? ?? const [];
      final sections = list
          .map((e) => WaterSection.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return sections;
    }
    throw Exception('获取水帖版块失败 (${response.statusCode})');
  }

  Future<WaterSection> fetchSection(String slug) async {
    final response = await _dio.get('/water/sections/$slug');
    if (response.statusCode == 200 && response.data != null) {
      final data = response.data;
      final section = data['section'];
      if (section is Map<String, dynamic>) {
        return WaterSection.fromJson(section);
      }
    }
    throw Exception('获取水帖版块失败 (${response.statusCode})');
  }
}