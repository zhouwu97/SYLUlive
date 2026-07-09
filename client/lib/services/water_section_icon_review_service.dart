import 'package:dio/dio.dart';
import '../models/water_section_icon_review.dart';

class WaterSectionIconReviewService {
  final Dio _dio;

  WaterSectionIconReviewService(this._dio);

  Future<WaterSectionIconReviewState> getCurrentSectionIconReview(
      String slug) async {
    final response =
        await _dio.get('/water/sections/$slug/icon-review/current');
    if (response.statusCode == 200 && response.data != null) {
      return WaterSectionIconReviewState.fromJson(response.data);
    }
    throw Exception('获取图标审核状态失败');
  }

  Future<WaterSectionIconReview> submitSectionIconReview(
      String slug, String newAvatarUrl, String reason) async {
    final response = await _dio.post(
      '/water/sections/$slug/icon-review',
      data: {
        'new_avatar_url': newAvatarUrl,
        'reason': reason,
      },
    );
    if (response.statusCode == 200 && response.data != null) {
      return WaterSectionIconReview.fromJson(response.data);
    }
    throw Exception('提交审核申请失败');
  }

  Future<void> cancelSectionIconReview(String slug, int id) async {
    final response =
        await _dio.post('/water/sections/$slug/icon-review/$id/cancel');
    if (response.statusCode != 200) {
      throw Exception('撤回申请失败');
    }
  }

  Future<List<WaterSectionIconReview>> adminListSectionIconReviews(
      {String status = 'pending'}) async {
    final response = await _dio.get('/admin/water/section-icon-reviews',
        queryParameters: {'status': status});
    if (response.statusCode == 200 && response.data != null) {
      final list = response.data['reviews'] as List<dynamic>? ?? const [];
      return list
          .map(
              (e) => WaterSectionIconReview.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('获取审核列表失败');
  }

  Future<WaterSectionIconReview> adminApproveSectionIconReview(
      int id, String reason) async {
    final response = await _dio.post(
      '/admin/water/section-icon-reviews/$id/approve',
      data: {'review_reason': reason},
    );
    if (response.statusCode == 200 && response.data != null) {
      return WaterSectionIconReview.fromJson(response.data);
    }
    throw Exception('审核通过失败');
  }

  Future<WaterSectionIconReview> adminRejectSectionIconReview(
      int id, String reason) async {
    final response = await _dio.post(
      '/admin/water/section-icon-reviews/$id/reject',
      data: {'review_reason': reason},
    );
    if (response.statusCode == 200 && response.data != null) {
      return WaterSectionIconReview.fromJson(response.data);
    }
    throw Exception('审核拒绝失败');
  }
}
