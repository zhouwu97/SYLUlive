import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_home.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';

/// 首页「今日推荐」Hero 卡：回答“今天吃什么”。
/// 展示综合分、真实星级与评价人数、可解释的推荐理由与体验标签。
class CanteenHeroRecommendationCard extends StatefulWidget {
  final CanteenHero hero;
  final VoidCallback onTap;

  const CanteenHeroRecommendationCard({
    super.key,
    required this.hero,
    required this.onTap,
  });

  @override
  State<CanteenHeroRecommendationCard> createState() =>
      _CanteenHeroRecommendationCardState();
}

class _CanteenHeroRecommendationCardState
    extends State<CanteenHeroRecommendationCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final h = widget.hero;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.985 : 1.0,
        duration: AppMotion.micro,
        curve: AppMotion.standard,
        child: Container(
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
            border: Border.all(color: CanteenTheme.borderColor(isDark)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      size: 16, color: CanteenTheme.accentColor(isDark)),
                  const SizedBox(width: 6),
                  Text(
                    h.title.isEmpty ? '今日推荐' : h.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: CanteenTheme.textPrimaryColor(isDark),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Hero(
                    tag: 'canteen-${h.canteenId}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                      child: SizedBox(
                        width: 84,
                        height: 84,
                        child: _buildCover(isDark),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          h.canteenName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: CanteenTheme.textPrimaryColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _buildMetaRow(isDark),
                        if (h.rankingScore > 0) ...[
                          const SizedBox(height: 6),
                          Text(
                            '综合分 ${h.rankingScore.round()}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.accentStrongColor(isDark),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (h.reason.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  h.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
              if (h.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: h.tags
                      .map((t) => _tagChip(isDark, t))
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetaRow(bool isDark) {
    return Row(
      children: [
        Icon(Icons.star_rounded,
            size: 15, color: CanteenTheme.accentColor(isDark)),
        const SizedBox(width: 3),
        Text(
          h.averageStar > 0 ? h.averageStar.toStringAsFixed(1) : '暂无评分',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: CanteenTheme.textPrimaryColor(isDark),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          h.ratingCount > 0 ? '${h.ratingCount} 人评价' : '暂无评价',
          style: TextStyle(
            fontSize: 12,
            color: CanteenTheme.textSecondaryColor(isDark),
          ),
        ),
      ],
    );
  }

  CanteenHero get h => widget.hero;

  Widget _tagChip(bool isDark, String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: CanteenTheme.accentSoftColor(isDark),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: CanteenTheme.accentStrongColor(isDark),
        ),
      ),
    );
  }

  Widget _buildCover(bool isDark) {
    if (h.image.isEmpty) {
      return Container(
        color: CanteenTheme.surfaceMutedBg(isDark),
        alignment: Alignment.center,
        child: Icon(Icons.restaurant_rounded,
            size: 28, color: CanteenTheme.textTertiaryColor(isDark)),
      );
    }
    return CachedNetworkImage(
      imageUrl: ApiConstants.fullUrl(h.image),
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => _placeholder(isDark),
      placeholder: (_, __) => _placeholder(isDark),
    );
  }

  Widget _placeholder(bool isDark) {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      alignment: Alignment.center,
      child: Icon(Icons.restaurant_rounded,
          size: 28, color: CanteenTheme.textTertiaryColor(isDark)),
    );
  }
}
