import 'package:flutter/material.dart';

import '../../models/water_section.dart';
import '../../theme/app_colors.dart';

/// 版块频道入口卡片。
/// 展示版块的公告/规则，敏感版块额外显示安全提醒条。
class SectionChannelCard extends StatelessWidget {
  final WaterSection section;
  final Color accentColor;
  final bool isDark;

  const SectionChannelCard({
    super.key,
    required this.section,
    required this.accentColor,
    required this.isDark,
  });

  String _effectiveNoticeText() {
    final cfg = _channelConfig(section.slug);
    final sensitiveSlug = section.sensitiveLevel == 'caution' ||
        section.sensitiveLevel == 'strict';
    return section.noticeText.isNotEmpty
        ? section.noticeText
        : (sensitiveSlug ? cfg.defaultNotice : '');
  }

  @override
  Widget build(BuildContext context) {
    final noticeText = _effectiveNoticeText();
    final cfg = _channelConfig(section.slug);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: _buildChannelCard(cfg),
        ),
        if (noticeText.isNotEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildNoticeBar(noticeText),
          ),
        ],
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildChannelCard(_ChannelConfig cfg) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? AppColors.borderNormalDark
              : AppColors.borderNormalLight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: isDark ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.campaign_outlined, size: 20, color: accentColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cfg.channelName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cfg.channelDesc,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight,
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeBar(String notice) {
    final isStrict = section.sensitiveLevel == 'strict';
    final color = isStrict ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.25 : 0.20),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isStrict
                ? Icons.report_problem_outlined
                : Icons.info_outline_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              notice,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: isDark ? color.withValues(alpha: 0.9) : color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelConfig {
  final String channelName;
  final String channelDesc;
  final String defaultNotice;

  const _ChannelConfig({
    required this.channelName,
    required this.channelDesc,
    this.defaultNotice = '',
  });
}

_ChannelConfig _channelConfig(String slug) {
  switch (slug) {
    case 'campus_life':
      return const _ChannelConfig(
        channelName: '生活频道',
        channelDesc: '聊食堂、宿舍、校园卡、随手拍，记录校园日常',
      );
    case 'course_study':
      return const _ChannelConfig(
        channelName: '课程答疑频道',
        channelDesc: '问选课、考试、老师评分，分享学习资料',
      );
    case 'freshman_help':
      return const _ChannelConfig(
        channelName: '新生频道',
        channelDesc: '问宿舍、报到、军训、校园卡，新生问题都可以来',
      );
    case 'competition':
      return const _ChannelConfig(
        channelName: '竞赛频道',
        channelDesc: '找队友、看通知、分享经验，竞赛从这里开始',
      );
    case 'complaint':
      return const _ChannelConfig(
        channelName: '树洞',
        channelDesc: '情绪倾诉、烦恼分享，说出来会好一些',
        defaultNotice: '请勿挂人、曝光隐私或攻击他人，保护自己也保护别人。',
      );
    case 'experience':
      return const _ChannelConfig(
        channelName: '经验频道',
        channelDesc: '攻略、总结、避坑，把有用的经验沉淀下来',
      );
    case 'campus_news':
      return const _ChannelConfig(
        channelName: '提醒频道',
        channelDesc: '发布风险提醒、真实反馈，帮更多同学少踩坑',
        defaultNotice: '请描述事实，避免挂人、造谣或曝光他人隐私。',
      );
    default:
      return const _ChannelConfig(
        channelName: '版块频道',
        channelDesc: '在这里分享你的想法和经历',
      );
  }
}
