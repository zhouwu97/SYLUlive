import 'package:flutter/material.dart';

import '../../theme/app_radius.dart';
import 'campus_theme.dart';

/// “今日”单条入口：每个 item 独立降级，任何一项不可用都不影响其它项。
class CampusTodayItem {
  const CampusTodayItem({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

/// 校园首页“今日”卡片：面向今天的高频信息入口。
///
/// 数据必须来自已有 Provider / 本地缓存 / 异步 freshness 刷新，
/// 禁止在 build 中触发请求风暴；每项点击都有明确跳转目标。
class CampusTodayCard extends StatelessWidget {
  const CampusTodayCard({
    super.key,
    required this.items,
    required this.isDark,
  });

  final List<CampusTodayItem> items;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final subtitleColor = colors.onSurfaceVariant;
    final iconColor = colors.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: CampusTheme.cardDecoration(isDark),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.today_rounded,
                    size: 17,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '今日',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '帮你盯住今天的重要安排',
                      style: TextStyle(
                        fontSize: 12,
                        color: subtitleColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final item in items) _buildItem(context, item, iconColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    CampusTodayItem item,
    Color iconColor,
  ) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('campus-today-${item.id}'),
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
