import 'package:flutter/material.dart';
import '../../config/api_constants.dart';
import '../../models/canteen_home.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 首页“今天吃什么”Hero 卡。
///
/// 视觉上先让照片和可信综合分承担决策，再用三项体验维度解释分数；
/// 维度数据缺失时回退到现有平均分，兼容旧服务端响应。
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
                    tag: 'canteen-${h.canteenId}',
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
    return count > 0 ? '近 7 天 $count 条有效反馈' : '近期暂无有效反馈';
  }

  Widget _buildDimensionRow(bool isDark) {
    final values = [
      ('味道', _dimensionValue('taste')),
      ('性价比', _dimensionValue('value')),
      ('排队效率', _dimensionValue('queue')),
    ];
    return Row(
      children: [
        for (var i = 0; i < values.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(
              children: [
                Text(
                  values[i].$2 > 0 ? values[i].$2.toStringAsFixed(1) : '—',
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
    );
  }

  double _dimensionValue(String key) {
    final value = h.dimensionScores[key] ?? 0;
    return value > 0 ? value : h.averageStar;
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
      imageUrl: ApiConstants.fullUrl(h.image),
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
