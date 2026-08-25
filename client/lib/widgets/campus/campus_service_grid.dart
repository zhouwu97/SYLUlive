import 'package:flutter/material.dart';
import '../../theme/app_radius.dart';
import 'campus_theme.dart';
import 'campus_service_item.dart';

class CampusServiceGrid extends StatelessWidget {
  final bool isDark;
  final VoidCallback onEduTap;
  final VoidCallback onCanteenTap;
  final VoidCallback onRateTap;
  final VoidCallback onTeamTap;
  final VoidCallback onMapTap;
  final VoidCallback onCalendarTap;

  const CampusServiceGrid({
    super.key,
    required this.isDark,
    required this.onEduTap,
    required this.onCanteenTap,
    required this.onRateTap,
    required this.onTeamTap,
    required this.onMapTap,
    required this.onCalendarTap,
  });

  @override
  Widget build(BuildContext context) {
    final services = [
      CampusServiceItem(
        title: '教务中心',
        icon: Icons.school_rounded,
        color: CampusTheme.blue,
        onTap: onEduTap,
      ),
      CampusServiceItem(
        title: '食堂',
        icon: Icons.restaurant_rounded,
        color: CampusTheme.dining,
        onTap: onCanteenTap,
      ),
      CampusServiceItem(
        title: '校园榜单',
        icon: Icons.leaderboard_rounded,
        color: CampusTheme.orange,
        onTap: onRateTap,
      ),
      CampusServiceItem(
        title: '组队',
        icon: Icons.groups_2_rounded,
        color: CampusTheme.primary,
        onTap: onTeamTap,
      ),
      CampusServiceItem(
        title: '校园地图',
        icon: Icons.map_rounded,
        color: CampusTheme.cyan,
        onTap: onMapTap,
      ),
      CampusServiceItem(
        title: '校历',
        icon: Icons.calendar_month_rounded,
        color: CampusTheme.green,
        onTap: onCalendarTap,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '校园服务',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : CampusTheme.text,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '常用校园功能',
          style: TextStyle(
            fontSize: 12,
            color: CampusTheme.subText,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            gradient: isDark
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [CampusTheme.darkCard, Color(0xFF20272A)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white, Color(0xFFF7FCFA)],
                  ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : CampusTheme.primary.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : CampusTheme.primary)
                    .withValues(alpha: isDark ? 0.18 : 0.06),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width >= 1200 ? 6 : (width >= 700 ? 4 : 3);
                const gap = 8.0;
                final itemWidth = (width - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final service in services)
                      SizedBox(
                        width: itemWidth,
                        child: CampusServiceCard(
                          service: service,
                          isDark: isDark,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
