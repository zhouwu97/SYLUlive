import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../providers/campus_calendar_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_palette.dart';
import '../app_card.dart';

class CampusHeader extends StatelessWidget {
  final String semester;
  final DateTime? date;

  const CampusHeader({super.key, required this.semester, this.date});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glass = context.watch<ThemeProvider?>()?.frostedGlass == true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final now = date ?? DateTime.now();
    final dateStr = DateFormat('MM-dd').format(now);
    final calendar = context.watch<CampusCalendarProvider?>()?.calendar;
    final dayInfo = calendar?.dayInfo(now);
    final currentSemester = dayInfo?.semester;
    final week = dayInfo?.teachingWeek;
    final semesterText = currentSemester == null
        ? semester
        : '${calendar!.academicYear.replaceAll('-', '—')}学年 · ${currentSemester.name}';
    final progress = week == null || currentSemester == null
        ? null
        : (currentSemester.teachingWeeks.indexOf(week) + 1) /
            currentSemester.teachingWeeks.length;

    return AppCardSurface(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
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
            color: (isDark ? Colors.black : AppThemeTokens.of(context).primary)
                .withValues(alpha: isDark ? 0.16 : 0.05),
            blurRadius: 20,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '校园',
                  style: TextStyle(
                    fontSize: 28,
                    height: 1.1,
                    fontWeight: FontWeight.w900,
                    color: AppThemeTokens.of(context).textPrimary,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  semesterText,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppThemeTokens.of(context).textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // 右侧周次信息同时承担本学期进度提示。
          Container(
            key: const ValueKey('campus-week-badge'),
            width: 68,
            padding: const EdgeInsets.fromLTRB(7, 7, 7, 6),
            decoration: BoxDecoration(
              // 与页头共用一层材质，避免内部实色底遮住毛玻璃。
              color: glass
                  ? Colors.transparent
                  : AppThemeTokens.of(context)
                      .surfaceMuted
                      .withValues(alpha: isDark ? 1 : 0.78),
              borderRadius: BorderRadius.circular(AppShape.of(context).md),
              border: glass
                  ? null
                  : Border.all(
                      color: AppThemeTokens.of(context).cardBorder,
                    ),
            ),
            child: Column(
              children: [
                if (week != null) ...[
                  Text(
                    '第${week.week}周',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppThemeTokens.of(context).primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppThemeTokens.of(context).textSecondary,
                  ),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 5),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: reduceMotion ? Duration.zero : AppMotion.page,
                    curve: AppMotion.standard,
                    builder: (context, progress, child) {
                      return ClipRRect(
                        borderRadius:
                            BorderRadius.circular(AppShape.of(context).pill),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: progress,
                          backgroundColor:
                              AppThemeTokens.of(context).primary.withValues(
                                    alpha: isDark ? 0.16 : 0.1,
                                  ),
                          valueColor: AlwaysStoppedAnimation(
                            AppThemeTokens.of(context).primary,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
