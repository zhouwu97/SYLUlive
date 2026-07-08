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
    const cardPrimary = Color(0xFF168B7D);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: isDark ? CampusTheme.darkCard : Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.05),
                blurRadius: 16,
                spreadRadius: 0,
                offset: const Offset(0, 6),
              ),
            ],
            border: Border.all(
              color: isDark ? Colors.white12 : Colors.white,
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      cardPrimary.withValues(alpha: 0.15),
                      cardPrimary.withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _getIcon(),
                  size: 42,
                  color: cardPrimary.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _getTitle(),
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : CampusTheme.text,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 10),
              if (type == CourseEmptyStateType.noCache &&
                  recommendedTerm != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: cardPrimary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '推荐导入 ${recommendedTerm!.title}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cardPrimary.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                _getDescription(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white70 : CampusTheme.subText,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: cardPrimary,
                  boxShadow: [
                    BoxShadow(
                      color: cardPrimary.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: onMainAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _getMainActionText(),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white60 : CampusTheme.subText,
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
          const SizedBox(height: 20),
          const Text(
            '登录并绑定教务系统后即可解锁以上功能',
            style: TextStyle(
              fontSize: 11,
              color: CampusTheme.subText,
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
        return '还没有任何课表数据，可以从教务系统一键导入';
      case CourseEmptyStateType.currentTermNoCache:
        return '该学期暂无本地课表数据，你可以尝试从教务系统拉取';
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
        return '课表拉取';
    }
  }

  String _getSecondaryActionText() {
    switch (type) {
      case CourseEmptyStateType.unlogged:
        return '';
      case CourseEmptyStateType.unbound:
        return '也可以手动添加课程';
      case CourseEmptyStateType.noCache:
        return '切换历史学期';
      case CourseEmptyStateType.currentTermNoCache:
        return '也可以手动添加课程';
    }
  }
}
