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

  Future<WaterSection> updateSectionDisplay({
    required String slug,
    required Map<String, dynamic> fields,
  }) async {
    final response = await _dio.patch('/water/sections/$slug', data: fields);
    if (response.statusCode == 200 && response.data != null) {
      final section = response.data['section'];
      if (section is Map<String, dynamic>) {
        return WaterSection.fromJson(section);
      }
    }
    throw Exception('保存版块展示失败 (${response.statusCode})');
  }

  Future<WaterSectionTag> createTag({
    required String sectionSlug,
    required Map<String, dynamic> fields,
  }) async {
    final response =
        await _dio.post('/water/sections/$sectionSlug/tags', data: fields);
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        response.data != null) {
      final tag = response.data['tag'];
      if (tag is Map<String, dynamic>) {
        return WaterSectionTag.fromJson(tag);
      }
    }
    throw Exception('创建标签失败 (${response.statusCode})');
  }

  Future<WaterSectionTag> updateTag({
    required String sectionSlug,
    required int tagId,
    required Map<String, dynamic> fields,
  }) async {
    final response = await _dio.patch(
      '/water/sections/$sectionSlug/tags/$tagId',
      data: fields,
    );
    if (response.statusCode == 200 && response.data != null) {
      final tag = response.data['tag'];
      if (tag is Map<String, dynamic>) {
        return WaterSectionTag.fromJson(tag);
      }
    }
    throw Exception('保存标签失败 (${response.statusCode})');
  }

  Future<WaterSectionTag> updateTagStatus({
    required String sectionSlug,
    required int tagId,
    required bool isEnabled,
    String? reason,
  }) async {
    final response = await _dio.patch(
      '/water/sections/$sectionSlug/tags/$tagId/status',
      data: {
        'is_enabled': isEnabled,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    if (response.statusCode == 200 && response.data != null) {
      final tag = response.data['tag'];
      if (tag is Map<String, dynamic>) {
        return WaterSectionTag.fromJson(tag);
      }
    }
    throw Exception('更新标签状态失败 (${response.statusCode})');
  }
}
