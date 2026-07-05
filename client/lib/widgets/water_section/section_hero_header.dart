import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/water_section.dart';
import '../../models/water_section_my_level.dart';
import '../level_progress_pill.dart';
import 'section_avatar.dart';
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
  final WaterSectionMyLevel? myLevel;
  final VoidCallback onToggleFollow;

  const SectionHeroHeader({
    super.key,
    required this.section,
    required this.accentColor,
    required this.isFollowing,
    required this.isLoggedIn,
    this.myLevel,
    required this.onToggleFollow,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasCover = section.mobileCoverUrl.isNotEmpty;
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
              imageUrl: ApiConstants.fullUrl(section.mobileCoverUrl),
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
    final title = section.title.isNotEmpty ? section.title : section.slug;
    final subtitle = section.subtitle.isNotEmpty ? section.subtitle : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 图标 ──
        SectionAvatar(
          section: section,
          size: 52,
          radius: 16,
          accentColor: accentColor,
          showBorder: true,
          borderColor: Colors.white.withValues(alpha: 0.45),
          borderWidth: 1.5,
          isDark: hasCover || isDark,
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
    int level = 1;
    String? title;
    String expText = '';
    double progress = 0.0;
    bool isMaxLevel = false;

    if (!isFollowing) {
      level = 0;
      title = '未关注';
      expText = '关注后积攒经验';
      progress = 0.0;
    } else if (myLevel != null) {
      level = myLevel!.level;
      title = myLevel!.title;
      expText = '${myLevel!.exp}/${myLevel!.nextLevelExp}';
      progress = myLevel!.progressRatio;
      isMaxLevel = myLevel!.isMaxLevel;
    } else if (section.myLevel != null) {
      level = section.myLevel!.level;
      title = section.myLevel!.title;
      expText = '${section.myLevel!.exp}/${section.myLevel!.nextLevelExp}';
      progress = section.myLevel!.progress;
      isMaxLevel = section.myLevel!.isMaxLevel;
    }

    return LevelProgressPill(
      levelLabel: '本版 Lv.$level',
      title: title,
      expText: expText,
      progress: progress,
      accentColor: accentColor,
      darkOnImage: hasCover,
      isMaxLevel: isMaxLevel,
      isLoggedIn: isLoggedIn,
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
