import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

enum CourseMenuAction {
  syncFromEdu,
  switchTerm,
  setSemesterStart,
  archives,
  share,
  settings,
}

class CourseActionMenu extends StatelessWidget {
  final bool isDark;
  final Function(CourseMenuAction) onSelected;

  const CourseActionMenu({
    super.key,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<CourseMenuAction>(
      icon: Icon(
        Icons.more_horiz_rounded,
        color: isDark ? Colors.white : CampusTheme.text,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isDark ? CampusTheme.darkCard : Colors.white,
      elevation: 8,
      onSelected: onSelected,
      itemBuilder: (context) => [
        _buildItem(context, CourseMenuAction.syncFromEdu,
            Icons.cloud_download_rounded, '课表拉取'),
        _buildItem(context, CourseMenuAction.switchTerm,
            Icons.swap_horiz_rounded, '切换学期'),
        _buildItem(context, CourseMenuAction.setSemesterStart,
            Icons.event_rounded, '设置开学日期'),
        const PopupMenuDivider(),
        _buildItem(
            context, CourseMenuAction.archives, Icons.archive_rounded, '课表存档'),
        _buildItem(
            context, CourseMenuAction.share, Icons.share_rounded, '分享课表'),
        const PopupMenuDivider(),
        _buildItem(
            context, CourseMenuAction.settings, Icons.settings_rounded, '课表设置'),
      ],
    );
  }

  PopupMenuItem<CourseMenuAction> _buildItem(BuildContext context,
      CourseMenuAction action, IconData icon, String label) {
    return PopupMenuItem<CourseMenuAction>(
      value: action,
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isDark
                ? Colors.white70
                : CampusTheme.text.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : CampusTheme.text,
            ),
          ),
        ],
      ),
    );
  }
}
