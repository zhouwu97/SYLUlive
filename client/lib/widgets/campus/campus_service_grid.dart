import 'package:flutter/material.dart';
import 'campus_theme.dart';
import 'campus_service_item.dart';

class CampusServiceGrid extends StatelessWidget {
  final bool isDark;
  final VoidCallback onEduTap;
  final VoidCallback onRateTap;
  final VoidCallback onTeamTap;
  final VoidCallback onMapTap;
  final VoidCallback onCalendarTap;

  const CampusServiceGrid({
    super.key,
    required this.isDark,
    required this.onEduTap,
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
        title: '校园榜单',
        icon: Icons.leaderboard_rounded,
        color: CampusTheme.orange,
        onTap: onRateTap,
      ),
      CampusServiceItem(
        title: '组队',
        icon: Icons.groups_2_rounded,
        color: const Color(0xFF7C6FF0),
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
        Text(
          '常用校园功能',
          style: TextStyle(
            fontSize: 12,
            color: CampusTheme.subText,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: isDark ? CampusTheme.darkCard : Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : CampusTheme.softBorder.withValues(alpha: 0.5),
            ),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                for (var index = 0; index < services.length; index++)
                  Expanded(
                    child: CampusServiceCard(
                      service: services[index],
                      isDark: isDark,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
