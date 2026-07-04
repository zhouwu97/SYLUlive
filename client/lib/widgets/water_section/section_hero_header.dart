import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/water_section.dart';
import 'section_channel_card.dart';

/// 版块沉浸式头图，作为 Stack 底层使用。
///
/// 结构：背景层（图片/渐变）+ 遮罩 + 内容层（从上往下排）。
/// 放在 water_category_feed_screen 的 Stack 里，下方由
/// DraggableScrollableSheet 盖住一部分。
class SectionHeroHeader extends StatelessWidget {
  final WaterSection section;
  final Color accentColor;
  final bool isFollowing;
  final bool isLoggedIn;
  final VoidCallback onToggleFollow;

  const SectionHeroHeader({
    super.key,
    required this.section,
    required this.accentColor,
    required this.isFollowing,
    required this.isLoggedIn,
    required this.onToggleFollow,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasCover = section.coverUrl.isNotEmpty;
    final backgroundColor =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);
    // Hero 自身高度固定为屏幕高度的 72%，而不是 fit:expand 撑满整屏。
    // 这样默认 sheet(initialChildSize=0.66) 时只有顶部约 34% 可见，
    // 刚好压到等级卡/关注下面，不露大面积空背景；下拉 sheet 到 0.24
    // 才完整展示背景与频道卡。
    final heroHeight = MediaQuery.sizeOf(context).height * 0.72;

    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 背景层 ──
          if (hasCover)
            CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(section.coverUrl),
              fit: BoxFit.cover,
              placeholder: (_, __) =>
                  Container(color: accentColor.withValues(alpha: 0.3)),
              errorWidget: (_, __, ___) =>
                  _buildGradientBg(accentColor, backgroundColor),
            )
          else
            _buildGradientBg(accentColor, backgroundColor),

          // ── 遮罩 ──
          if (hasCover) _buildScrim(backgroundColor),

          // ── 内容层 ──
          SafeArea(
            bottom: false,
            child: Padding(
              // top 52 给操作栏留空间
              padding: const EdgeInsets.fromLTRB(18, 52, 18, 0),
              child: _buildContent(isDark, hasCover, context),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildGradientBg(Color accentColor, Color bgColor) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: 0.35),
            accentColor.withValues(alpha: 0.12),
            bgColor,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
    );
  }

  Widget _buildScrim(Color bgColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.35),
            Colors.black.withValues(alpha: 0.50),
            bgColor.withValues(alpha: 0.80),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }

  Widget _buildContent(bool isDark, bool hasCover, BuildContext context) {
    final textColor =
        (hasCover || isDark) ? Colors.white : const Color(0xFF151922);
    final mutedColor = textColor.withValues(alpha: 0.65);
    final icon =
        iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final title = section.title.isNotEmpty ? section.title : section.slug;
    final subtitle = section.subtitle.isNotEmpty ? section.subtitle : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 图标 ──
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: isDark ? 0.24 : 0.16),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.25),
              width: 1.5,
            ),
          ),
          child: Icon(icon, size: 26, color: accentColor),
        ),
        const SizedBox(height: 8),

        // ── 标题 ──
        Text(
          title,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: textColor,
            height: 1.2,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: mutedColor,
            ),
          ),
        ],

        // ── 等级卡 ──
        const SizedBox(height: 10),
        _buildLevelCard(isDark, hasCover),

        // ── 关注 + 统计 ──
        const SizedBox(height: 8),
        Row(
          children: [
            _buildFollowButton(isDark),
            const SizedBox(width: 12),
            _buildStatText('${section.postCount} 帖', mutedColor),
            _buildStatDot(mutedColor),
            _buildStatText('${section.followerCount} 关注', mutedColor),
          ],
        ),

        // ── 频道卡（底部，被 sheet 盖住一部分）──
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 0),
          child: SectionChannelCard(
            section: section,
            accentColor: accentColor,
            isDark: isDark,
          ),
        ),
      ],
    );
  }

  /// 等级卡：只展示本版等级 + 经验进度（不展示账号等级）
  Widget _buildLevelCard(bool isDark, bool hasCover) {
    final myLevel = section.myLevel;

    final cardColor = hasCover
        ? Colors.black.withValues(alpha: 0.35)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.85));

    final cardBorder = accentColor.withValues(alpha: 0.15);
    final textColor = hasCover || isDark
        ? Colors.white
        : const Color(0xFF151922);
    final mutedTextColor = hasCover
        ? Colors.white70
        : (isDark ? Colors.white60 : const Color(0xFF60646C));
    final hintColor = hasCover
        ? Colors.white60
        : (isDark ? Colors.white38 : const Color(0xFF9AA0A6));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cardBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.workspace_premium_rounded,
                  size: 14, color: accentColor),
              const SizedBox(width: 4),
              Text(
                '本版 Lv.${myLevel?.level ?? 1}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              if (myLevel != null && myLevel.title.isNotEmpty) ...[
                Text(
                  ' · ${myLevel.title}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: mutedTextColor,
                  ),
                ),
              ],
            ],
          ),
          if (myLevel != null && !myLevel.isMaxLevel) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: myLevel.progress.clamp(0.0, 1.0),
                      minHeight: 5,
                      backgroundColor: accentColor.withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation(accentColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${myLevel.exp}/${myLevel.nextLevelExp}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: mutedTextColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '再获得 ${myLevel.expToNext} 经验升级',
              style: TextStyle(fontSize: 10.5, color: hintColor),
            ),
          ] else if (myLevel != null && myLevel.isMaxLevel) ...[
            const SizedBox(height: 4),
            Text(
              '已满级',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: mutedTextColor,
              ),
            ),
          ] else if (!isLoggedIn) ...[
            const SizedBox(height: 4),
            Text(
              '登录后查看本版等级',
              style: TextStyle(fontSize: 11, color: hintColor),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFollowButton(bool isDark) {
    return GestureDetector(
      onTap: onToggleFollow,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isFollowing
              ? Colors.white.withValues(alpha: 0.15)
              : accentColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isFollowing
                ? Colors.white.withValues(alpha: 0.35)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          isFollowing ? '已关注' : '+ 关注',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: isFollowing
                ? Colors.white.withValues(alpha: 0.85)
                : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildStatText(String label, Color color) {
    return Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color),
    );
  }

  Widget _buildStatDot(Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '·',
        style:
            TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
