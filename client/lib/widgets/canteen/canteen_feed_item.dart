import 'package:flutter/material.dart';
import '../../config/api_constants.dart';
import '../../models/canteen_home.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 推荐信息流条目：按 type 分支渲染。
/// 商家类（recommended_store / stable_choice / trending）与实拍类（recent_photo）。
/// 所有卡片统一点按 → 进入对应商家详情页（P1 再做菜品深度定位）。
class CanteenFeedItemCard extends StatefulWidget {
  final CanteenFeedItem item;
  final VoidCallback onTap;

  const CanteenFeedItemCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  State<CanteenFeedItemCard> createState() => _CanteenFeedItemCardState();
}

class _CanteenFeedItemCardState extends State<CanteenFeedItemCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
        child: widget.item.isRecentPhoto
            ? _buildPhotoCard(isDark)
            : _buildStoreCard(isDark),
      ),
    );
  }

  // ── 商家类卡片（推荐 / 稳妥 / 热门）─────────────────────────────────

  Widget _buildStoreCard(bool isDark) {
    final item = widget.item;

    return Container(
      padding: const EdgeInsets.all(14),
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
              _typeTag(isDark, item.typeLabel),
              const Spacer(),
              if (item.rankingScore > 0)
                Text(
                  '综合 ${item.rankingScore.round()}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: CanteenTheme.textTertiaryColor(isDark),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: 'canteen-${item.canteenId}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                  child: SizedBox(
                    width: 80,
                    height: 76,
                    child: _buildImage(isDark),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.canteenName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
                    if (item.averageStar > 0) ...[
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Icon(Icons.star_rounded,
                              size: 14,
                              color: CanteenTheme.accentColor(isDark)),
                          const SizedBox(width: 2),
                          Text(
                            item.averageStar.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.textPrimaryColor(isDark),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${item.ratingCount} 人评价',
                            style: TextStyle(
                              fontSize: 12,
                              color: CanteenTheme.textSecondaryColor(isDark),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (item.reason.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        item.reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: CanteenTheme.textSecondaryColor(isDark),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (item.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: item.tags
                  .take(3)
                  .map((t) => _tagChip(isDark, t))
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }

  // ── 实拍类卡片 ────────────────────────────────────────────────────

  Widget _buildPhotoCard(bool isDark) {
    final item = widget.item;
    return Container(
      padding: const EdgeInsets.all(14),
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
              _typeTag(isDark, item.typeLabel),
            ],
          ),
          const SizedBox(height: 10),
          _photoGrid(isDark),
          const SizedBox(height: 10),
          Text(
            item.canteenName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          if (item.dishName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '最近实拍 · ${item.dishName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ],
          if (item.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _photoGrid(bool isDark) {
    final item = widget.item;
    final urls = item.images.isNotEmpty ? item.images : [item.image];
    final trimmed = urls.take(3).toList();
    final total = urls.length;

    return SizedBox(
      height: 92,
      child: Row(
        children: [
          for (var i = 0; i < trimmed.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: SizedBox(
                  height: 92,
                  child: _thumb(isDark, ApiConstants.fullUrl(trimmed[i])),
                ),
              ),
            ),
          ],
          if (total > 3) ...[
            const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: Container(
                  height: 92,
                  color: CanteenTheme.surfaceMutedBg(isDark),
                  alignment: Alignment.center,
                  child: Text(
                    '+${total - 3}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _thumb(bool isDark, String url) {
    return CanteenStatusImage(
      imageUrl: url,
      offline: widget.item.isOffline,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => _placeholder(isDark),
      placeholder: (_, __) => _placeholder(isDark),
    );
  }

  Widget _buildImage(bool isDark) {
    final item = widget.item;
    if (item.image.isEmpty) return _placeholder(isDark);
    return CanteenStatusImage(
      imageUrl: ApiConstants.fullUrl(item.image),
      offline: item.isOffline,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => _placeholder(isDark),
      placeholder: (_, __) => _placeholder(isDark),
    );
  }

  Widget _placeholder(bool isDark) {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        size: 26,
        color: CanteenTheme.textTertiaryColor(isDark),
      ),
    );
  }

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

  Widget _typeTag(bool isDark, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: CanteenTheme.accentSoftColor(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: CanteenTheme.accentStrongColor(isDark),
        ),
      ),
    );
  }
}

extension on CanteenFeedItem {
  String get typeLabel => switch (type) {
        CanteenFeedType.recommendedStore => '综合推荐',
        CanteenFeedType.trendingStore => '近期热门',
        CanteenFeedType.stableChoice => '评价稳定',
        CanteenFeedType.recentPhoto => '最近实拍',
        CanteenFeedType.newStore => '新收录',
        CanteenFeedType.caution => '注意',
        _ => '',
      };
}
