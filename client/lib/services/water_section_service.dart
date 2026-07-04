import 'package:dio/dio.dart';
import '../models/water_section.dart';
import '../models/water_section_level_title.dart';
import '../models/water_section_my_level.dart';

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

  Future<void> followSection(String slug) async {
    final response = await _dio.post('/water/sections/$slug/follow');
    if (response.statusCode != 200) {
      throw Exception('关注版块失败 (${response.statusCode})');
    }
  }

  Future<void> unfollowSection(String slug) async {
    final response = await _dio.delete('/water/sections/$slug/follow');
    if (response.statusCode != 200) {
      throw Exception('取消关注失败 (${response.statusCode})');
    }
  }

  Future<List<WaterSection>> fetchFollowedSections() async {
    final response = await _dio.get('/water/sections/followed');
    if (response.statusCode == 200 && response.data != null) {
      final data = response.data;
      final list = data['sections'] as List<dynamic>? ?? const [];
      final sections = list
          .map((e) => WaterSection.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return sections;
    }
    throw Exception('获取关注版块失败 (${response.statusCode})');
  }

  Future<WaterSectionMyLevel> fetchMyLevel(String sectionSlug) async {
    final response = await _dio.get('/water/sections/$sectionSlug/my-level');
    if (response.statusCode == 200 && response.data != null) {
      return WaterSectionMyLevel.fromJson(
        response.data as Map<String, dynamic>,
      );
    }
    throw Exception('获取版块等级失败 (${response.statusCode})');
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

  /// 拉取版块 Lv.1-Lv.8 等级称号列表（自定义缺失时使用默认值，由后端补齐）。
  Future<List<WaterSectionLevelTitle>> fetchLevelTitles(
    String sectionSlug,
  ) async {
    final response =
        await _dio.get('/water/sections/$sectionSlug/level-titles');
    if (response.statusCode == 200 && response.data != null) {
      final data = response.data;
      final list = data['titles'] as List<dynamic>? ?? const [];
      return list
          .map(
              (e) => WaterSectionLevelTitle.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('获取版块称号失败 (${response.statusCode})');
  }

  /// 批量更新版块等级称号。
  Future<List<WaterSectionLevelTitle>> updateLevelTitles({
    required String sectionSlug,
    required List<Map<String, dynamic>> titles,
  }) async {
    final response = await _dio.patch(
      '/water/sections/$sectionSlug/level-titles',
      data: {'titles': titles},
    );
    if (response.statusCode == 200 && response.data != null) {
      final list = response.data['titles'] as List<dynamic>? ?? const [];
      return list
          .map(
              (e) => WaterSectionLevelTitle.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('更新版块称号失败 (${response.statusCode})');
  }
}
