import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/announcement.dart' as model;
import '../models/water_section.dart';
import '../providers/theme_provider.dart';
import 'group_chat_dialog.dart';
import 'water_section/section_avatar.dart';

/// 校园服务抽屉 —— 纯展示组件，所有数据和回调由外部提供。
class HomeServiceDrawer extends StatelessWidget {
  final bool checkedIn;
  final int streakDays;
  final bool checkInLoading;
  final bool showCheckInDot;
  final List<model.Announcement> announcements;
  final List<model.Announcement> unreadAnnouncements;
  final VoidCallback onCheckIn;
  final VoidCallback onOpenToolbox;
  final VoidCallback onOpenAnnouncements;
  final VoidCallback onOpenCompetitions;
  final VoidCallback onOpenGrades;
  final VoidCallback onOpenExamSchedule;
  final VoidCallback onOpenFeedback;
  final VoidCallback onOpenWaterSectionDirectory;
  final ValueChanged<WaterPostCategory>? onOpenWaterCategory;
  final ValueChanged<WaterSection>? onOpenWaterSection;
  final List<WaterSection> waterSections;
  final bool waterSectionsLoading;

  const HomeServiceDrawer({
    super.key,
    required this.checkedIn,
    required this.streakDays,
    required this.checkInLoading,
    required this.showCheckInDot,
    required this.announcements,
    required this.unreadAnnouncements,
    required this.onCheckIn,
    required this.onOpenToolbox,
    required this.onOpenAnnouncements,
    required this.onOpenCompetitions,
    required this.onOpenGrades,
    required this.onOpenExamSchedule,
    required this.onOpenFeedback,
    required this.onOpenWaterSectionDirectory,
    this.onOpenWaterCategory,
    this.onOpenWaterSection,
    this.waterSections = const [],
    this.waterSectionsLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final drawerWidth = (screenWidth * 0.8).clamp(0.0, 360.0);

    final themeProvider = context.watch<ThemeProvider>();
    final isCustomMode = !themeProvider.isCleanBackgroundMode;

    final drawerBg = isDark
        ? const Color(0xFF151A24)
        : isCustomMode
            ? kCleanWarmBackgroundLight.withValues(alpha: 0.96)
            : kCleanWarmBackgroundLight;

    return Container(
      width: drawerWidth,
      decoration: BoxDecoration(
        color: drawerBg,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
            blurRadius: 24,
            offset: const Offset(8, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, isDark),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
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

  // ---- 快捷入口（签到、工具箱）----
  Widget _buildQuickEntries(BuildContext context, bool isDark) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : kCleanWarmCardBorderLight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _CompactQuickEntryItem(
              icon: Icons.task_alt_rounded,
              iconColor: checkedIn ? Colors.grey : const Color(0xFF16A34A),
              title: checkedIn ? '签到记录' : '签到',
              isDark: isDark,
              isLoading: checkInLoading,
              showDot: showCheckInDot,
              onTap: onCheckIn,
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

  // ---- 公告中心 ----
  Widget _buildAnnouncementSection(BuildContext context, bool isDark) {
    final preview = unreadAnnouncements.isNotEmpty
        ? unreadAnnouncements.first
        : (announcements.isNotEmpty ? announcements.first : null);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpenAnnouncements,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : kCleanWarmCardBorderLight,
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
                      '公告中心',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  if (unreadAnnouncements.isNotEmpty) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${unreadAnnouncements.length} 条未读',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: isDark ? Colors.white38 : Colors.black26,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (preview == null)
                Text(
                  '暂无公告',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                )
              else ...[
                Text(
                  preview.title,
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
                  preview.content,
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

  // ---- 社区版块 ----
  Widget _buildWaterCategorySection(BuildContext context, bool isDark) {
    final sections = _resolvedSections;
    final categoryCount = sections.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(
                    '社区版块',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : const Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : const Color(0xFFF4F6F8),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      waterSectionsLoading ? '加载中' : '$categoryCount 个版块',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF6B7280),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: onOpenWaterSectionDirectory,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '全部',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(width: 1),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          decoration: BoxDecoration(
            color:
                isDark ? Colors.white.withValues(alpha: 0.045) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : kCleanWarmCardBorderLight,
            ),
          ),
          child: waterSectionsLoading
              ? SizedBox(
                  height: 80,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final itemWidth = (constraints.maxWidth - 10) / 2;
                    final displaySections = sections.take(4).toList();
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: displaySections.map((section) {
                        return SizedBox(
                          width: itemWidth,
                          child: _WaterCategoryMiniItem(
                            section: section,
                            isDark: isDark,
                            onTap: () => _openCategory(section),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openCategory(WaterSection section) {
    if (onOpenWaterSection != null) {
      onOpenWaterSection!(section);
    } else if (onOpenWaterCategory != null) {
      // legacy fallback: convert WaterSection → WaterPostCategory
      final legacy = waterCategoryOf(section.slug);
      if (legacy != null) {
        onOpenWaterCategory!(legacy);
      }
    }
  }

  /// 动态版块（来自 provider）优先；为空或接口失败时兜底到本地 taxonomy。
  List<WaterSection> get _resolvedSections {
    if (waterSections.isNotEmpty) return waterSections;
    return kWaterPostCategories.map(WaterSection.fromLegacyCategory).toList();
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
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF111827),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color:
                isDark ? Colors.white.withValues(alpha: 0.045) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : kCleanWarmCardBorderLight,
            ),
          ),
          child: Column(
            children: [
              _ServiceRow(
                icon: Icons.workspace_premium_outlined,
                color: const Color(0xFFD97706),
                title: '竞赛中心',
                subtitle: '比赛日历',
                isDark: isDark,
                onTap: onOpenCompetitions,
              ),
              _buildServiceDivider(isDark),
              _ServiceRow(
                icon: Icons.assessment_outlined,
                color: const Color(0xFF5D64C4),
                title: '成绩查询',
                subtitle: '查看学期成绩与绩点',
                isDark: isDark,
                onTap: onOpenGrades,
              ),
              _buildServiceDivider(isDark),
              _ServiceRow(
                icon: Icons.event_note_rounded,
                color: const Color(0xFF8B5CF6),
                title: '考试安排',
                subtitle: 'AI 一键提取',
                isDark: isDark,
                onTap: onOpenExamSchedule,
              ),
              _buildServiceDivider(isDark),
              _ServiceRow(
                icon: Icons.feedback_outlined,
                color: const Color(0xFF0EA5E9),
                title: '意见反馈',
                subtitle: 'Bug 报告与功能建议',
                isDark: isDark,
                onTap: onOpenFeedback,
              ),
              _buildServiceDivider(isDark),
              _ServiceRow(
                icon: Icons.group_rounded,
                color: const Color(0xFF2563EB),
                title: '加入群聊',
                subtitle: '扫码进群交流反馈',
                isDark: isDark,
                onTap: () => showGroupChatDialog(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildServiceDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 58, right: 14),
      child: Divider(
        height: 1,
        thickness: 1,
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFEFF3F8),
      ),
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
  final WaterSection section;
  final bool isDark;
  final VoidCallback onTap;

  const _WaterCategoryMiniItem({
    required this.section,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = colorHexToColor(section.colorHex);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 74,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color:
                isDark ? Colors.white.withValues(alpha: 0.045) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : kCleanWarmCardBorderLight,
            ),
          ),
          child: Row(
            children: [
              SectionAvatar(
                section: section,
                size: 34,
                radius: 13,
                accentColor: color,
                isDark: isDark,
                showBorder: false, // 服务抽屉不需要明显描边
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      section.subtitle.isNotEmpty
                          ? section.subtitle
                          : section.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(13),
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
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.15,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF8A93A3),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: isDark ? Colors.white30 : const Color(0xFFB8C0CC),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
