import 'package:flutter/material.dart';
import '../../models/canteen_home.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 首页“今天吃什么”Hero 卡。
///
/// 视觉上先让照片和可信综合分承担决策，再用三项体验维度解释分数；
/// 维度数据缺失时明确展示缺省状态，不把综合分伪装成五维数据。
class CanteenHeroRecommendationCard extends StatefulWidget {
  final CanteenHero hero;
  final VoidCallback onTap;
  final String? heroTag;

  const CanteenHeroRecommendationCard({
    super.key,
    required this.hero,
    required this.onTap,
    this.heroTag,
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
    final heroTag = widget.heroTag ?? 'canteen-home-hero-${h.canteenId}';

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedOpacity(
        opacity: _pressed ? 0.94 : 1.0,
        duration: AppMotion.micro,
        curve: AppMotion.standard,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
            border: Border.all(color: CanteenTheme.borderColor(isDark)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Hero(
                    tag: heroTag,
                    child: SizedBox(
                      width: double.infinity,
                      height: 176,
                      child: _buildCover(isDark),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.52),
                          ],
                          stops: const [0.42, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 13,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.canteenName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black38,
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                              ),
                              if (h.locationLabel.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  h.locationLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 3),
                              Text(
                                _recentFeedbackLabel,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (h.rankingScore > 0)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    h.rankingScore.round().toString(),
                                    style: const TextStyle(
                                      fontSize: 30,
                                      height: 1,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 2),
                                    child: Text(
                                      '分',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                '可信综合分',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
                child: _buildDimensionRow(isDark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _recentFeedbackLabel {
    final count = h.recentReviewCount > 0
        ? h.recentReviewCount
        : (h.visitReviewCount > 0 ? h.visitReviewCount : h.ratingCount);
    return count > 0 ? '近 7 天 $count 条商家评价' : '近 7 天暂无商家评价';
  }

  Widget _buildDimensionRow(bool isDark) {
    final values = <(String, double?)>[
      ('味道', _dimensionValue('taste')),
      ('性价比', _dimensionValue('value')),
      ('排队效率', _dimensionValue('queue')),
    ];
    final hasAnyDimension = values.any((item) => item.$2 != null);
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < values.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      values[i].$2?.toStringAsFixed(1) ?? '—',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      values[i].$1,
                      style: TextStyle(
                        fontSize: 10,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (!hasAnyDimension) ...[
          const SizedBox(height: 8),
          Text(
            h.averageStar > 0
                ? '综合评价 ${h.averageStar.toStringAsFixed(1)} · 五维数据待补充'
                : '暂无足够五维评价',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
        ],
      ],
    );
  }

  double? _dimensionValue(String key) {
    final value = h.dimensionScores[key] ?? 0;
    return value > 0 ? value : null;
  }

  CanteenHero get h => widget.hero;

  Widget _buildCover(bool isDark) {
    if (h.image.isEmpty) {
      return Container(
        color: CanteenTheme.surfaceMutedBg(isDark),
        alignment: Alignment.center,
        child: Icon(Icons.restaurant_rounded,
            size: 28, color: CanteenTheme.textTertiaryColor(isDark)),
      );
    }
    return CanteenStatusImage(
      imageUrl: h.image,
      variant: 'medium',
      offline: h.operatingStatus == 'offline',
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
