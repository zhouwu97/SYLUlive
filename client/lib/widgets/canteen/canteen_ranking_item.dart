import '../app_card.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_ranking.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_spacing.dart';
import 'canteen_location_chip.dart';
import 'canteen_status_image.dart';
import 'canteen_theme.dart';

/// 完整排行页条目：排版数字排名 + 封面 + 名称 + 星级/评价人数 + 综合分 + 样本提示 + 标签。
/// rank 由服务端返回，客户端不自行 index+1。
class CanteenRankingItemTile extends StatefulWidget {
  final CanteenRankingItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const CanteenRankingItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<CanteenRankingItemTile> createState() => _CanteenRankingItemTileState();
}

class _CanteenRankingItemTileState extends State<CanteenRankingItemTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final item = widget.item;

    return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: AppContentSurface.card(
            child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTapDown: (_) => setState(() => _pressed = true),
                      onTapUp: (_) => setState(() => _pressed = false),
                      onTapCancel: () => setState(() => _pressed = false),
                      onTap: widget.onTap,
                      onLongPress: widget.onLongPress,
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedOpacity(
                        opacity: _pressed ? 0.94 : 1.0,
                        duration: AppMotion.micro,
                        curve: AppMotion.standard,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 排名：纯排版数字
                            Padding(
                              padding: const EdgeInsets.only(left: 2, top: 2),
                              // 没人评价的店不占名次，用“—”占位并配读屏说明。
                              child: Semantics(
                                label: item.ranked
                                    ? '第${item.rank}名'
                                    : '暂无评价，不参与排名',
                                excludeSemantics: true,
                                child: Text(
                                  item.ranked
                                      ? item.rank.toString().padLeft(2, '0')
                                      : '—',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.6,
                                    height: 1.1,
                                    color: item.ranked
                                        ? CanteenTheme.rankColor(item.rank)
                                        : CanteenTheme.rankColor(99),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Hero(
                              tag: 'canteen-ranking-${item.id}',
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                    CanteenTheme.radiusMd),
                                child: SizedBox(
                                  width: 96,
                                  height: 88,
                                  child: _buildCover(isDark),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            item.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w800,
                                              color:
                                                  CanteenTheme.textPrimaryColor(
                                                      isDark),
                                            ),
                                          ),
                                        ),
                                        if (item.rankingScore > 0) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                            '综合分 ${item.rankingScore.round()}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: CanteenTheme
                                                  .accentStrongColor(isDark),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        Icon(Icons.star_rounded,
                                            size: 14,
                                            color: CanteenTheme.accentColor(
                                                isDark)),
                                        Text(
                                          item.averageStar > 0
                                              ? item.averageStar
                                                  .toStringAsFixed(1)
                                              : '暂无',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color:
                                                CanteenTheme.textPrimaryColor(
                                                    isDark),
                                          ),
                                        ),
                                        Text(
                                          '${item.ratingCount} 人评价',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: appContentSecondaryColor(
                                                context,
                                                CanteenTheme.textSecondaryColor(
                                                    isDark)),
                                          ),
                                        ),
                                        if (item.isOffline)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color:
                                                  CanteenTheme.surfaceMutedBg(
                                                      isDark),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                  color:
                                                      CanteenTheme.borderColor(
                                                          isDark)),
                                            ),
                                            child: Text(
                                              '已下架',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                                color: CanteenTheme
                                                    .textSecondaryColor(isDark),
                                              ),
                                            ),
                                          ),
                                        if (item.locationLabel.isNotEmpty) ...[
                                          CanteenLocationChip(
                                              label: item.locationLabel),
                                        ],
                                        if (item.sampleHint.isNotEmpty) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color:
                                                  CanteenTheme.surfaceMutedBg(
                                                      isDark),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              item.sampleHint,
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: CanteenTheme
                                                    .textSecondaryColor(isDark),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (item.summaryTags.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        item.summaryTags
                                            .take(3)
                                            .map((t) => t.name)
                                            .join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: appContentSecondaryColor(
                                              context,
                                              CanteenTheme.textTertiaryColor(
                                                  isDark)),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ))));
  }

  Widget _buildCover(bool isDark) {
    if (widget.item.image.isEmpty) return _placeholder(isDark);
    return CanteenStatusImage(
      imageUrl: ApiConstants.fullUrl(widget.item.image),
      variant: 'thumb',
      offline: widget.item.isOffline,
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
          size: 26,
          color: appContentSecondaryColor(
              context, CanteenTheme.textTertiaryColor(isDark))),
    );
  }
}
