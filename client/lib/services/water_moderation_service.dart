import 'package:dio/dio.dart';

import '../models/water_moderation.dart';

/// 水帖版块内容管理服务
class WaterModerationService {
  final Dio _dio;

  WaterModerationService(this._dio);

  String _base(String slug) => '/water/sections/$slug';

  // ── 置顶 ──

  Future<WaterSectionPin> pinPost({
    required String sectionSlug,
    required int postId,
    int weight = 0,
    String? reason,
    DateTime? pinnedUntil,
  }) async {
    final body = <String, dynamic>{
      'weight': weight,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      if (pinnedUntil != null)
        'pinned_until': pinnedUntil.toUtc().toIso8601String(),
    };
    final resp = await _dio.post(
      '${_base(sectionSlug)}/posts/$postId/pin',
      data: body,
    );
    return WaterSectionPin.fromJson(
      resp.data['pin'] as Map<String, dynamic>,
    );
  }

  Future<void> unpinPost({
    required String sectionSlug,
    required int postId,
  }) async {
    await _dio.delete('${_base(sectionSlug)}/posts/$postId/pin');
  }

  // ── 加精 ──

  /// 返回响应体（含服务端回传的 home_application 审核状态），失败时抛出 DioException。
  Future<Map<String, dynamic>?> featurePost({
    required String sectionSlug,
    required int postId,
    required String reason,
  }) async {
    final response = await _dio.post(
      '${_base(sectionSlug)}/posts/$postId/feature',
      data: {'reason': reason},
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  Future<void> unfeaturePost({
    required String sectionSlug,
    required int postId,
  }) async {
    await _dio.delete('${_base(sectionSlug)}/posts/$postId/feature');
  }

  // ── 删帖 ──

  Future<void> deletePostByModerator({
    required String sectionSlug,
    required int postId,
    required String reason,
  }) async {
    await _dio.delete(
      '${_base(sectionSlug)}/posts/$postId/moderate',
      data: {'reason': reason},
    );
  }

  Future<void> restorePost({
    required String sectionSlug,
    required int postId,
    String? reason,
  }) async {
    final body = <String, dynamic>{};
    if (reason != null && reason.trim().isNotEmpty) {
      body['reason'] = reason.trim();
    }
    await _dio.post(
      '${_base(sectionSlug)}/posts/$postId/restore',
      data: body,
    );
  }

  // ── 禁言 ──

  Future<WaterSectionMute> muteUser({
    required String sectionSlug,
    required int userId,
    required String reason,
    required DateTime until,
  }) async {
    final resp = await _dio.post(
      '${_base(sectionSlug)}/users/$userId/mute',
      data: {
        'reason': reason,
        'until': until.toUtc().toIso8601String(),
      },
    );
    return WaterSectionMute.fromJson(
      resp.data['mute'] as Map<String, dynamic>,
    );
  }

  Future<void> unmuteUser({
    required String sectionSlug,
    required int userId,
    String? reason,
  }) async {
    final body = <String, dynamic>{};
    if (reason != null && reason.isNotEmpty) body['reason'] = reason;
    await _dio.delete(
      '${_base(sectionSlug)}/users/$userId/mute',
      data: body,
    );
  }

  // ── 列表 ──

  Future<List<WaterSectionMute>> fetchMutes(String sectionSlug) async {
    final resp = await _dio.get('${_base(sectionSlug)}/mutes');
    final list = (resp.data['mutes'] as List<dynamic>?) ?? [];
    return list
        .map((e) => WaterSectionMute.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<WaterModerationLogPage> fetchLogs({
    required String sectionSlug,
    int page = 1,
    int pageSize = 20,
    String? action,
  }) async {
    final params = <String, dynamic>{
      'page': page,
      'page_size': pageSize,
    };
    if (action != null) params['action'] = action;
    final resp = await _dio.get(
      '${_base(sectionSlug)}/moderation/logs',
      queryParameters: params,
    );
    return WaterModerationLogPage.fromJson(
      resp.data as Map<String, dynamic>,
    );
  }
}
