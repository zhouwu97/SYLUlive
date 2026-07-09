import 'package:dio/dio.dart';

import '../models/water_moderator.dart';

/// 水帖版主管理服务 — 调用后端版主任命/修改/罢免/查询接口。
class WaterModeratorService {
  final Dio _dio;

  WaterModeratorService(this._dio);

  // ── 公开 ──

  /// GET /api/water/sections/:slug/my-permission
  Future<WaterSectionPermission> fetchMyPermission(String sectionSlug) async {
    final response =
        await _dio.get('/water/sections/$sectionSlug/my-permission');
    final data = response.data;
    if (data is Map && data['permission'] is Map) {
      return WaterSectionPermission.fromJson(
          Map<String, dynamic>.from(data['permission']));
    }
    return WaterSectionPermission.empty();
  }

  // ── 管理员 ──

  /// GET /api/admin/water/sections/:slug/moderators
  Future<List<WaterSectionModerator>> fetchModerators(
      String sectionSlug) async {
    final response =
        await _dio.get('/admin/water/sections/$sectionSlug/moderators');
    final data = response.data;
    final list = data['moderators'] as List<dynamic>? ?? [];
    return list
        .map((e) => WaterSectionModerator.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/admin/water/sections/:slug/moderators
  Future<WaterSectionModerator> createModerator({
    required String sectionSlug,
    required int userId,
    required String role,
    required bool canEditSection,
    required bool canManageTags,
    required bool canPinPost,
    required bool canDeletePost,
    required bool canMuteUser,
    String? reason,
  }) async {
    final response = await _dio.post(
      '/admin/water/sections/$sectionSlug/moderators',
      data: {
        'user_id': userId,
        'role': role,
        'can_edit_section': canEditSection,
        'can_manage_tags': canManageTags,
        'can_pin_post': canPinPost,
        'can_delete_post': canDeletePost,
        'can_mute_user': canMuteUser,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      },
    );
    return WaterSectionModerator.fromJson(
        response.data['moderator'] as Map<String, dynamic>);
  }

  /// PATCH /api/admin/water/sections/:slug/moderators/:moderatorId
  Future<WaterSectionModerator> updateModerator({
    required String sectionSlug,
    required int moderatorId,
    String? role,
    bool? canEditSection,
    bool? canManageTags,
    bool? canPinPost,
    bool? canDeletePost,
    bool? canMuteUser,
    String? reason,
  }) async {
    final body = <String, dynamic>{};
    if (role != null) body['role'] = role;
    if (canEditSection != null) body['can_edit_section'] = canEditSection;
    if (canManageTags != null) body['can_manage_tags'] = canManageTags;
    if (canPinPost != null) body['can_pin_post'] = canPinPost;
    if (canDeletePost != null) body['can_delete_post'] = canDeletePost;
    if (canMuteUser != null) body['can_mute_user'] = canMuteUser;
    if (reason != null && reason.isNotEmpty) body['reason'] = reason;

    final response = await _dio.patch(
      '/admin/water/sections/$sectionSlug/moderators/$moderatorId',
      data: body,
    );
    return WaterSectionModerator.fromJson(
        response.data['moderator'] as Map<String, dynamic>);
  }

  /// DELETE /api/admin/water/sections/:slug/moderators/:moderatorId
  Future<void> revokeModerator({
    required String sectionSlug,
    required int moderatorId,
    String? reason,
  }) async {
    final body = <String, dynamic>{};
    if (reason != null && reason.isNotEmpty) body['reason'] = reason;

    await _dio.delete(
      '/admin/water/sections/$sectionSlug/moderators/$moderatorId',
      data: body,
    );
  }
}
