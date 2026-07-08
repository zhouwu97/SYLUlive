import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/water_section.dart';
import '../../models/water_section_my_level.dart';
import '../level_progress_pill.dart';
import 'section_avatar.dart';

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
  final double topContentInset;
  final double bottomContentInset;
  final VoidCallback onToggleFollow;

  const SectionHeroHeader({
    super.key,
    required this.section,
    required this.accentColor,
    required this.isFollowing,
    required this.isLoggedIn,
    this.myLevel,
    required this.topContentInset,
    this.bottomContentInset = 120,
    required this.onToggleFollow,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasCover = section.mobileCoverUrl.isNotEmpty;
    final backgroundColor =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);
    // Hero 自身高度铺满全屏，下方内容由 bottomContentInset 提供可滚动空间，避免被 sheet 挡住
    final heroHeight = MediaQuery.sizeOf(context).height;

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
          Padding(
            padding: EdgeInsets.fromLTRB(16, topContentInset, 16, 0),
            child: _buildContent(isDark, hasCover, context),
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

        // ── 下拉展开的信息区 ──
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(0, 0, 0, bottomContentInset),
            child: Column(
              children: [
                _buildGrowthCard(isDark, hasCover, mutedColor),
                const SizedBox(height: 10),
                _buildDescriptionCard(isDark, hasCover, mutedColor),
                const SizedBox(height: 20),
                _buildDataCapsules(isDark, hasCover, mutedColor),
              ],
            ),
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
          color:
              isFollowing ? Colors.white.withValues(alpha: 0.15) : accentColor,
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

  Widget _buildGrowthCard(bool isDark, bool hasCover, Color mutedColor) {
    int level = 1;
    int expToNext = 0;
    bool isMaxLevel = false;

    if (myLevel != null) {
      level = myLevel!.level;
      expToNext = myLevel!.nextLevelExp - myLevel!.exp;
      isMaxLevel = myLevel!.isMaxLevel;
    } else if (section.myLevel != null) {
      level = section.myLevel!.level;
      expToNext = section.myLevel!.expToNext;
      isMaxLevel = section.myLevel!.isMaxLevel;
    }

    if (expToNext < 0) expToNext = 0;

    final cardBg = (hasCover || isDark)
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.white.withValues(alpha: 0.8);
    final borderColor = (hasCover || isDark)
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.5);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('今日成长',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: mutedColor)),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildExpSourceItem('发帖', '+5', mutedColor),
              const SizedBox(width: 12),
              _buildExpSourceItem('评论', '+2', mutedColor),
              const SizedBox(width: 12),
              _buildExpSourceItem('被点赞', '+1', mutedColor),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            !isFollowing
                ? '关注后解锁版块等级'
                : isMaxLevel
                    ? '已达到最高等级'
                    : '距离 Lv.${level + 1} 还差 $expToNext 经验',
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildExpSourceItem(String label, String value, Color mutedColor) {
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: mutedColor)),
        const SizedBox(width: 4),
        Text(value,
            style: TextStyle(
                fontSize: 13, color: accentColor, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildDescriptionCard(bool isDark, bool hasCover, Color mutedColor) {
    final textColor =
        (hasCover || isDark) ? Colors.white : const Color(0xFF151922);
    final cardBg = (hasCover || isDark)
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.white.withValues(alpha: 0.8);
    final borderColor = (hasCover || isDark)
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.5);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('版块说明',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: mutedColor)),
          const SizedBox(height: 8),
          Text(
            section.description.isNotEmpty
                ? section.description
                : '校园日常、宿舍食堂、校园卡、随手拍、校园见闻。',
            style: TextStyle(fontSize: 14, color: textColor, height: 1.4),
          ),
          const SizedBox(height: 10),
          _buildRuleItem('· 不发广告和引流', textColor),
          const SizedBox(height: 4),
          _buildRuleItem('· 不挂人、不泄露隐私', textColor),
          const SizedBox(height: 4),
          _buildRuleItem('· 友善交流，求助尽量带图', textColor),
        ],
      ),
    );
  }

  Widget _buildRuleItem(String text, Color color) {
    return Text(text,
        style: TextStyle(
            fontSize: 13, color: color.withValues(alpha: 0.85), height: 1.4));
  }

  Widget _buildDataCapsules(bool isDark, bool hasCover, Color mutedColor) {
    final textColor =
        (hasCover || isDark) ? Colors.white : const Color(0xFF151922);

    Widget buildItem(String label, String value) {
      return Expanded(
        child: Center(
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(
                    text: '$label ',
                    style: TextStyle(
                        fontSize: 14,
                        color: mutedColor,
                        fontWeight: FontWeight.w600,
                        height: 1.0)),
                TextSpan(
                    text: value,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                        height: 1.0)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        buildItem('今日', '-'),
        buildItem('本周', '-'),
        buildItem('关注', '${section.followerCount}'),
        buildItem('精华', '-'),
      ],
    );
  }
}
