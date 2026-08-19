import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';

/// 食堂排行卡：图片优先，无白色大卡、无 rank badge、无阴影。
/// 排名使用排版数字（01/02/03），图片 104x96 圆角 14，整行底部分割线。
class CanteenRankingCard extends StatefulWidget {
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
  State<CanteenRankingCard> createState() => _CanteenRankingCardState();
}

class _CanteenRankingCardState extends State<CanteenRankingCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            scale: _pressed ? 0.985 : 1.0,
            duration: AppMotion.micro,
            curve: AppMotion.standard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 排名：纯排版数字，无底色 / badge / 阴影
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    widget.rank.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                      height: 1.1,
                      color: CanteenTheme.rankColor(widget.rank),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 封面 104x96，圆角 14，Hero 用于列表→详情过渡
                    Hero(
                      tag: 'canteen-${widget.canteenId}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                        child: SizedBox(
                          width: 104,
                          height: 96,
                          child: _buildCover(isDark),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: CanteenTheme.textPrimaryColor(isDark),
                              ),
                            ),
                            const SizedBox(height: 7),
                            Row(
                              children: [
                                Icon(
                                  Icons.star_rounded,
                                  size: 15,
                                  color: CanteenTheme.accentColor(isDark),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.averageStar.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: CanteenTheme.textPrimaryColor(isDark),
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Text(
                                  '${widget.ratingCount} 人评价',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        CanteenTheme.textSecondaryColor(isDark),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            Text(
                              widget.dishCount > 0
                                  ? '${widget.dishCount} 道菜 · ${widget.dishPhotoCount} 张实拍'
                                  : '暂无同学实拍',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: CanteenTheme.textTertiaryColor(isDark),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Divider(
          height: 1,
          thickness: 0.5,
          color: CanteenTheme.borderColor(isDark),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildCover(bool isDark) {
    if (widget.imageUrl.isEmpty) {
      return Container(
        color: CanteenTheme.surfaceMutedBg(isDark),
        alignment: Alignment.center,
        child: Icon(
          Icons.restaurant_rounded,
          size: 28,
          color: CanteenTheme.textTertiaryColor(isDark),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: ApiConstants.fullUrl(widget.imageUrl),
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
        size: 28,
        color: CanteenTheme.textTertiaryColor(isDark),
      ),
    );
  }
}
