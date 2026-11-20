import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme_style.dart';
import '../../theme/app_palette.dart';
import 'campus_theme.dart';
import 'campus_service_item.dart';
import '../app_card.dart';

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
        themeKey: 'edu',
        icon: Icons.school_rounded,
        color: CampusTheme.blue,
        onTap: onEduTap,
      ),
      CampusServiceItem(
        title: '食堂',
        themeKey: 'canteen',
        icon: Icons.restaurant_rounded,
        color: CampusTheme.dining,
        onTap: onCanteenTap,
      ),
      CampusServiceItem(
        title: '校园榜单',
        themeKey: 'ranking',
        icon: Icons.leaderboard_rounded,
        color: CampusTheme.orange,
        onTap: onRateTap,
      ),
      CampusServiceItem(
        title: '组队',
        themeKey: 'team',
        icon: Icons.groups_2_rounded,
        color: AppThemeTokens.of(context).primary,
        onTap: onTeamTap,
      ),
      CampusServiceItem(
        title: '校园地图',
        themeKey: 'map',
        icon: Icons.map_rounded,
        color: CampusTheme.cyan,
        onTap: onMapTap,
      ),
      CampusServiceItem(
        title: '校历',
        themeKey: 'calendar',
        icon: Icons.calendar_month_rounded,
        color: CampusTheme.green,
        onTap: onCalendarTap,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ThemeSectionTitle(
            '校园服务',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppThemeTokens.of(context).textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '常用校园功能',
            style: TextStyle(
              fontSize: 12,
              color: AppThemeTokens.of(context).textSecondary,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        ThemeOrnamented(
          slot: 'campusServices',
          child: AppCardSurface(
          decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppThemeTokens.of(context).card,
                  AppThemeTokens.of(context).primaryContainer
                ]),
            borderRadius: BorderRadius.circular(AppShape.of(context).lg),
            border: Border.all(
              color: AppThemeTokens.of(context).cardBorder,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    (isDark ? Colors.black : AppThemeTokens.of(context).primary)
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
        ),
      ],
    );
  }
}
