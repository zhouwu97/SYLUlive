import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../rating_detail/rating_report_sheet.dart';

/// 举报菜品页里的一条评价。
///
/// 菜品评价可能来自两种记录：带菜品评分的子记录（canteen_dish_review）或
/// 只关联了菜品的到店评价（canteen_review）。举报必须落到实际承载内容的那条记录上。
Future<void> reportDishReview(
  BuildContext context,
  Map<String, dynamic> review,
) async {
  final dishReviewId = (review['dish_review_id'] as num?)?.toInt() ?? 0;
  final parentReviewId = (review['review_id'] as num?)?.toInt() ??
      (review['id'] as num?)?.toInt() ??
      0;
  final isParentReview = review['review_source'] == 'canteen_review_event';
  final targetType = !isParentReview && dishReviewId > 0
      ? 'canteen_dish_review'
      : 'canteen_review';
  final targetId =
      targetType == 'canteen_dish_review' ? dishReviewId : parentReviewId;
  if (targetId == 0) return;
  await showRatingReportSheet(
    context: context,
    targetType: targetType,
    targetId: targetId,
    onSubmit: (reasonCode, description) async {
      try {
        final response = await context.read<AuthProvider>().dio.post(
          '/reports',
          data: {
            'target_type': targetType,
            'target_id': targetId,
            'reason_code': reasonCode,
            'reason': description.trim().isEmpty
                ? '举报原因：$reasonCode'
                : description.trim(),
          },
        );
        if (response.statusCode == 201 || response.statusCode == 200) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('举报已提交，感谢你的反馈')),
            );
          }
          return true;
        }
      } on DioException catch (error) {
        if (context.mounted) {
          final data = error.response?.data;
          final message = data is Map
              ? (data['message'] ?? data['error'])?.toString() ?? '举报提交失败'
              : '举报提交失败';
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      }
      return false;
    },
  );
}

/// 菜品评价里的三维分文案，例如“味道 5 · 性价比 4 · 分量 3”；没打分时返回空串。
String dishReviewScoreLine(Map<String, dynamic> review) {
  int score(String primary, [String? fallback]) =>
      (review[primary] as num?)?.toInt() ??
      (fallback == null ? null : (review[fallback] as num?)?.toInt()) ??
      0;
  final isParent = review['review_source'] == 'canteen_review_event';
  // 到店评价自身的 taste/value 是商家维度，只有菜品子评分才算菜的分。
  final taste = isParent ? score('dish_taste_score') : score('taste_score');
  final value = isParent ? score('dish_value_score') : score('value_score');
  final portion = score('portion_score');
  if (taste <= 0 || value <= 0 || portion <= 0) return '';
  return '味道 $taste · 性价比 $value · 分量 $portion';
}
