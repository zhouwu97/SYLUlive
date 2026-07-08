import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';
import '../../models/course_term.dart';

enum CourseEmptyStateType { unlogged, unbound, noCache, currentTermNoCache }

class CourseEmptyStateCard extends StatelessWidget {
  final CourseEmptyStateType type;
  final bool isDark;
  final VoidCallback onMainAction;
  final VoidCallback? onSecondaryAction;
  final CourseTerm? recommendedTerm;

  const CourseEmptyStateCard({
    super.key,
    required this.type,
    required this.isDark,
    required this.onMainAction,
    this.onSecondaryAction,
    this.recommendedTerm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '课表',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: isDark ? Colors.white : CampusTheme.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _getSubtitle(),
          style: const TextStyle(
            fontSize: 14,
            color: CampusTheme.subText,
          ),
        ),
        const SizedBox(height: 32),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: CampusTheme.cardDecoration(isDark),
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                _getIcon(),
                size: 48,
                color: CampusTheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                _getTitle(),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
              const SizedBox(height: 8),
              if (type == CourseEmptyStateType.noCache &&
                  recommendedTerm != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: CampusTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '推荐导入 ${recommendedTerm!.title}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: CampusTheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                _getDescription(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: CampusTheme.subText,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onMainAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: CampusTheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  _getMainActionText(),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onSecondaryAction != null) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: onSecondaryAction,
                  style: TextButton.styleFrom(
                    foregroundColor: CampusTheme.subText,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _getSecondaryActionText(),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ]
            ],
          ),
        ),
        if (type == CourseEmptyStateType.unlogged) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(child: _buildFeatureItem(Icons.sync_rounded, '教务导入')),
                Expanded(child: _buildFeatureItem(Icons.edit_rounded, '自定义课程')),
                Expanded(
                    child: _buildFeatureItem(Icons.widgets_rounded, '桌面小组件')),
                Expanded(
                    child: _buildFeatureItem(
                        Icons.notifications_active_rounded, '上课提醒')),
              ],
            ),
          ),
        ],
        if (type == CourseEmptyStateType.noCache) ...[
          const SizedBox(height: 24),
          const Text(
            '1 选择学期  ·  2 预览课程  ·  3 设置开学第一周',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: CampusTheme.subText,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFeatureItem(IconData icon, String label) {
    return Column(
      children: [
        Icon(icon, size: 24, color: CampusTheme.subText),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: CampusTheme.subText,
          ),
        ),
      ],
    );
  }

  String _getSubtitle() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '同步教务课表、课程提醒、桌面小组件';
      case CourseEmptyStateType.unbound:
      case CourseEmptyStateType.noCache:
      case CourseEmptyStateType.currentTermNoCache:
        return '你的专属课程表';
    }
  }

  IconData _getIcon() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return Icons.calendar_month_rounded;
      case CourseEmptyStateType.unbound:
        return Icons.link_off_rounded;
      case CourseEmptyStateType.noCache:
      case CourseEmptyStateType.currentTermNoCache:
        return Icons.inbox_rounded;
    }
  }

  String _getTitle() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '登录后使用课表';
      case CourseEmptyStateType.unbound:
        return '还没有绑定教务账号';
      case CourseEmptyStateType.noCache:
        return '还没有课表';
      case CourseEmptyStateType.currentTermNoCache:
        return '当前学期暂无课表';
    }
  }

  String _getDescription() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '登录后可绑定教务系统，同步课表并设置上课提醒';
      case CourseEmptyStateType.unbound:
        return '绑定后可从教务系统导入课表';
      case CourseEmptyStateType.noCache:
        return '该学期暂无本地课表，可以从教务系统导入或切换学期';
      case CourseEmptyStateType.currentTermNoCache:
        return '选择学期后先预览课程，确认后导入';
    }
  }

  String _getMainActionText() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '去登录';
      case CourseEmptyStateType.unbound:
        return '绑定教务账号';
      case CourseEmptyStateType.noCache:
      case CourseEmptyStateType.currentTermNoCache:
        return '从教务导入课表';
    }
  }

  String _getSecondaryActionText() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '';
      case CourseEmptyStateType.unbound:
        return '也可以手动添加课程';
      case CourseEmptyStateType.noCache:
        return '切换学期';
      case CourseEmptyStateType.currentTermNoCache:
        return '也可以手动添加课程';
    }
  }
}
