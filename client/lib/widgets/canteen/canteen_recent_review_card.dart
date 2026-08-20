import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_home.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';

/// 首页“同学最近在吃”独立评价卡。
///
/// 该卡只表达一条真实评价，不复用旧 Feed 卡片，避免把推荐类型误认为标题。
class CanteenRecentReviewCard extends StatefulWidget {
  final CanteenHomeReview review;
  final VoidCallback onTap;

  const CanteenRecentReviewCard({
    super.key,
    required this.review,
    required this.onTap,
  });

  @override
  State<CanteenRecentReviewCard> createState() =>
      _CanteenRecentReviewCardState();
}

class _CanteenRecentReviewCardState extends State<CanteenRecentReviewCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final review = widget.review;

    return Semantics(
      button: true,
      label: '${review.canteenName}的同学评价',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? 0.99 : 1,
          duration: AppMotion.micro,
          curve: AppMotion.standard,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceBg(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
              border: Border.all(color: CanteenTheme.borderColor(isDark)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildAvatar(isDark, review),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            review.userName.isEmpty ? '同学' : review.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: CanteenTheme.textPrimaryColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${_formatTime(review.createdAt)} · ${_historyLabel(review)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: CanteenTheme.textTertiaryColor(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (review.creditScore > 0) ...[
                      const SizedBox(width: 8),
                      _buildCreditPill(isDark, review.creditScore),
                    ],
                    const SizedBox(width: 8),
                    _buildScore(isDark, review.overallScore),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  review.canteenName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                if (review.comment.trim().isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    review.comment.trim(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ],
                if (_pills.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final pill in _pills.take(3))
                        _buildInfoPill(isDark, pill),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<String> get _pills {
    final review = widget.review;
    final pills = <String>[];
    for (final dish in review.recommendedDishes) {
      if (dish.trim().isNotEmpty) pills.add(dish.trim());
    }
    const labels = <String, String>{
      'taste': '味道',
      'value': '性价比',
      'queue': '排队效率',
      'hygiene': '卫生',
      'service': '服务',
    };
    for (final entry in review.dimensionScores.entries) {
      if (entry.value > 0 && labels.containsKey(entry.key)) {
        pills.add('${labels[entry.key]} ${entry.value.toStringAsFixed(1)}');
      }
    }
    return pills;
  }

  Widget _buildAvatar(bool isDark, CanteenHomeReview review) {
    final avatar = review.userAvatar.trim();
    return Container(
      width: 34,
      height: 34,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: CanteenTheme.accentSoftColor(isDark),
      ),
      alignment: Alignment.center,
      child: avatar.isEmpty
          ? Text(
              _initial(review.userName),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: CanteenTheme.accentStrongColor(isDark),
              ),
            )
          : CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(avatar),
              width: 34,
              height: 34,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Center(
                child: Text(
                  _initial(review.userName),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.accentStrongColor(isDark),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildCreditPill(bool isDark, int score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.successSurfaceDark
            : AppColors.successSurfaceLight,
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Text(
        '诚信 $score',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: isDark ? const Color(0xFF7CE3A9) : AppColors.success,
        ),
      ),
    );
  }

  Widget _buildScore(bool isDark, double score) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded,
            size: 16, color: CanteenTheme.accentColor(isDark)),
        const SizedBox(width: 2),
        Text(
          score > 0 ? score.toStringAsFixed(1) : '—',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: CanteenTheme.textPrimaryColor(isDark),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoPill(bool isDark, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: CanteenTheme.textSecondaryColor(isDark),
        ),
      ),
    );
  }

  String _historyLabel(CanteenHomeReview review) {
    if (review.historyCount > 0) return '第${review.historyCount}次评价这家店';
    return '最近到店评价';
  }

  String _formatTime(DateTime? createdAt) {
    if (createdAt == null || createdAt.millisecondsSinceEpoch == 0) return '最近';
    final local = createdAt.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (sameDay) {
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '今天 $hour:$minute';
    }
    return '${local.month}月${local.day}日';
  }

  String _initial(String name) {
    final value = name.trim();
    if (value.isEmpty) return '同';
    return String.fromCharCode(value.runes.first);
  }
}
