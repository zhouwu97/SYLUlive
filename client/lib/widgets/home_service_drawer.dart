import 'package:flutter/material.dart';

import '../config/water_post_taxonomy.dart';
import '../models/announcement.dart' as model;

/// 校园服务抽屉 —— 纯展示组件，所有数据和回调由外部提供。
class HomeServiceDrawer extends StatelessWidget {
  final bool checkedIn;
  final int streakDays;
  final bool checkInLoading;
  final bool showCheckInDot;
  final List<model.Announcement> announcements;
  final VoidCallback onCheckIn;
  final VoidCallback onOpenLostFound;
  final VoidCallback onOpenToolbox;
  final VoidCallback onOpenAnnouncements;
  final VoidCallback onOpenCompetitions;
  final VoidCallback onOpenGrades;
  final VoidCallback onOpenExamSchedule;
  final VoidCallback onOpenFeedback;
  final VoidCallback onOpenAllWaterPosts;
  final ValueChanged<WaterPostCategory> onOpenWaterCategory;

  const HomeServiceDrawer({
    super.key,
    required this.checkedIn,
    required this.streakDays,
    required this.checkInLoading,
    required this.showCheckInDot,
    required this.announcements,
    required this.onCheckIn,
    required this.onOpenLostFound,
    required this.onOpenToolbox,
    required this.onOpenAnnouncements,
    required this.onOpenCompetitions,
    required this.onOpenGrades,
    required this.onOpenExamSchedule,
    required this.onOpenFeedback,
    required this.onOpenAllWaterPosts,
    required this.onOpenWaterCategory,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final drawerWidth = (screenWidth * 0.8).clamp(0.0, 360.0);

    return Container(
      width: drawerWidth,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181D28) : Colors.white,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, isDark),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAnnouncementSection(context, isDark),
                    const SizedBox(height: 16),
                    _buildQuickEntries(context, isDark),
                    const SizedBox(height: 16),
                    _buildWaterCategorySection(context, isDark),
                    const SizedBox(height: 20),
                    _buildMoreServices(context, isDark),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 标题区域 ----
  Widget _buildHeader(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '校园服务',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '常用功能与校园通知',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- 三个快捷入口（签到、失物招领、工具箱）----
  Widget _buildQuickEntries(BuildContext context, bool isDark) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE9EDF5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _CompactQuickEntryItem(
              icon: Icons.task_alt_rounded,
              iconColor: checkedIn ? Colors.grey : const Color(0xFF16A34A),
              title: checkedIn ? '已签到' : '签到',
              isDark: isDark,
              isLoading: checkInLoading,
              showDot: showCheckInDot,
              onTap: onCheckIn,
            ),
          ),
          _buildQuickDivider(isDark),
          Expanded(
            child: _CompactQuickEntryItem(
              icon: Icons.luggage_outlined,
              iconColor: const Color(0xFF0EA5A4),
              title: '失物招领',
              isDark: isDark,
              onTap: onOpenLostFound,
            ),
          ),
          _buildQuickDivider(isDark),
          Expanded(
            child: _CompactQuickEntryItem(
              icon: Icons.handyman_outlined,
              iconColor: const Color(0xFFF97316),
              title: '工具箱',
              isDark: isDark,
              onTap: onOpenToolbox,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickDivider(bool isDark) {
    return Container(
      width: 1,
      height: 24,
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : const Color(0xFFE5E7EB),
    );
  }

  // ---- 系统公告 ----
  Widget _buildAnnouncementSection(BuildContext context, bool isDark) {
    final latest = announcements.isNotEmpty ? announcements.first : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpenAnnouncements,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : const Color(0xFFF7F9FC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE9EDF5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.campaign_outlined,
                      color: Color(0xFF3B82F6),
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '系统公告',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  if (announcements.isNotEmpty)
                    Text(
                      announcements.length.toString(),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF3B82F6),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: isDark ? Colors.white38 : Colors.black26,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (latest == null)
                Text(
                  '暂无新公告',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                )
              else ...[
                Text(
                  latest.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  latest.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- 水帖分类 ----
  Widget _buildWaterCategorySection(BuildContext context, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '水帖分类',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
            InkWell(
              onTap: onOpenAllWaterPosts,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '全部',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF6B7280),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 15,
                      color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = (constraints.maxWidth - 20) / 3;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: kWaterPostCategories.map((category) {
                return SizedBox(
                  width: itemWidth,
                  child: _WaterCategoryMiniItem(
                    category: category,
                    isDark: isDark,
                    onTap: () => onOpenWaterCategory(category),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  // ---- 更多服务 ----
  Widget _buildMoreServices(BuildContext context, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '更多服务',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(height: 10),
        _ServiceRow(
          icon: Icons.workspace_premium_outlined,
          color: const Color(0xFFD97706),
          title: '竞赛中心',
          subtitle: '比赛日历',
          isDark: isDark,
          onTap: onOpenCompetitions,
        ),
        const SizedBox(height: 8),
        _ServiceRow(
          icon: Icons.assessment_outlined,
          color: const Color(0xFF5D64C4),
          title: '成绩查询',
          subtitle: '查看学期成绩与绩点',
          isDark: isDark,
          onTap: onOpenGrades,
        ),
        const SizedBox(height: 8),
        _ServiceRow(
          icon: Icons.event_note_rounded,
          color: Colors.deepPurpleAccent,
          title: '考试安排',
          subtitle: 'AI 一键提取',
          isDark: isDark,
          onTap: onOpenExamSchedule,
        ),
        const SizedBox(height: 8),
        _ServiceRow(
          icon: Icons.feedback_outlined,
          color: const Color(0xFF0EA5E9),
          title: '意见反馈',
          subtitle: 'Bug 报告与功能建议',
          isDark: isDark,
          onTap: onOpenFeedback,
        ),
      ],
    );
  }
}

// ---- 快捷入口卡片 ----
class _CompactQuickEntryItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final bool isDark;
  final bool isLoading;
  final bool showDot;
  final VoidCallback onTap;

  const _CompactQuickEntryItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.isDark,
    this.isLoading = false,
    this.showDot = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: isLoading ? null : onTap,
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                isLoading
                    ? SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: iconColor,
                        ),
                      )
                    : Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : const Color(0xFF20232A),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showDot)
            Positioned(
              top: 9,
              right: 12,
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaterCategoryMiniItem extends StatelessWidget {
  final WaterPostCategory category;
  final bool isDark;
  final VoidCallback onTap;

  const _WaterCategoryMiniItem({
    required this.category,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 48,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(category.icon, size: 17, color: category.color),
            ),
            const SizedBox(height: 3),
            Text(
              category.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF374151),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 更多服务条目 ----
class _ServiceRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _ServiceRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: isDark ? Colors.white38 : Colors.black26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
