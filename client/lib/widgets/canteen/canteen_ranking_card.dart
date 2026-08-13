import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../rating_detail/ranking_tokens.dart';

/// 食堂排行卡：独立于学科/专业通用卡的视觉卡。
/// 展示封面、名称、评分、评价数与菜品实拍统计。
class CanteenRankingCard extends StatelessWidget {
  final int rank;
  final int canteenId;
  final String name;
  final String imageUrl;
  final double averageStar;
  final int ratingCount;
  final int dishCount;
  final int dishPhotoCount;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const CanteenRankingCard({
    super.key,
    required this.rank,
    required this.canteenId,
    required this.name,
    this.imageUrl = '',
    required this.averageStar,
    required this.ratingCount,
    this.dishCount = 0,
    this.dishPhotoCount = 0,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    return Padding(
      padding: EdgeInsets.only(bottom: RankingTokens.cardGap),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(RankingTokens.cardRadius),          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: RankingTokens.cardDecoration(isDark),
            child: Row(
              children: [
                // 左侧封面 96x88 + 排名 badge
                SizedBox(
                  width: 96,
                  height: 88,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _buildCover(isDark),
                      Positioned(
                        top: -6,
                        left: -6,
                        child: _buildRankBadge(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // 右侧信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: RankingTokens.titleColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 16,
                            color: Color(0xFFFFB800),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            averageStar.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$ratingCount 条评价',
                            style: TextStyle(
                              fontSize: 12,
                              color: RankingTokens.subColor(isDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        dishCount > 0
                            ? '$dishCount 道菜 · $dishPhotoCount 张同学实拍'
                            : '暂无实拍',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: RankingTokens.mutedColor(isDark),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: RankingTokens.subColor(isDark),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(bool isDark) {
    final hasImage = imageUrl.isNotEmpty;
    return Container(
      width: 96,
      height: 88,
      decoration: BoxDecoration(
        color: hasImage ? null : RankingTokens.canteenAccentSoft(isDark),
        borderRadius: BorderRadius.circular(14),
        image: hasImage
            ? DecorationImage(
                image: CachedNetworkImageProvider(ApiConstants.fullUrl(imageUrl)),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: hasImage
          ? null
          : Icon(
              Icons.restaurant_rounded,
              size: 28,
              color: RankingTokens.canteenAccent(isDark),
            ),
    );
  }

  Widget _buildRankBadge() {
    final color = switch (rank) {
      1 => const Color(0xFFFFB800),
      2 => const Color(0xFF94A3B8),
      3 => const Color(0xFFCA8A4B),
      _ => const Color(0xFF9CA3AF),
    };
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$rank',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}
