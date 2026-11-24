import '../../features/theme_pack/theme_presentation.dart';
import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme_style.dart';
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
    final tokens = AppThemeTokens.of(context);
    final shape = AppShape.of(context);

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

    Widget buildWeekBadge({required bool opaqueCard, bool inline = false}) {
      return Container(
        key: const ValueKey('campus-week-badge'),
        constraints: BoxConstraints(minWidth: inline ? 0 : 68),
        padding: inline
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : const EdgeInsets.fromLTRB(7, 7, 7, 6),
        decoration: BoxDecoration(
          color: (!opaqueCard && glass)
              ? Colors.transparent
              : tokens.surfaceMuted.withValues(alpha: isDark ? 1 : 0.78),
          borderRadius: BorderRadius.circular(shape.md),
          border: (!opaqueCard && glass)
              ? null
              : Border.all(color: tokens.cardBorder),
        ),
        child: inline
            ? Text(
                week != null ? '第${week.week}周 · $dateStr' : dateStr,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: tokens.primary,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (week != null) ...[
                    Text(
                      '第${week.week}周',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: tokens.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    dateStr,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: tokens.textSecondary,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 5),
                    SizedBox(
                      width: 54,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: progress),
                        duration: reduceMotion ? Duration.zero : AppMotion.page,
                        curve: AppMotion.standard,
                        builder: (context, progress, child) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(shape.pill),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              value: progress,
                              backgroundColor: tokens.primary.withValues(
                                alpha: isDark ? 0.16 : 0.1,
                              ),
                              valueColor: AlwaysStoppedAnimation(
                                tokens.primary,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
      );
    }

    return ThemeHeaderFrame(
      slot: 'campus',
      ornamentSlot: 'campusHeader',
      defaultBuilder: (_) => AppCardSurface(
        applyCardStyle: false,
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tokens.card,
              tokens.primaryContainer,
            ],
          ),
          borderRadius: BorderRadius.circular(shape.lg),
          border: Border.all(color: tokens.cardBorder),
          boxShadow: [
            BoxShadow(
              color: (isDark ? Colors.black : tokens.primary)
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
                    style: AppThemeStyle.of(context).title(TextStyle(
                      fontSize: 28,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                      color: tokens.textPrimary,
                    )),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    semesterText,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            buildWeekBadge(opaqueCard: false),
          ],
        ),
      ),
      standardInfoBuilder: (_, layout) {
        final titleColumn = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: layout.crossAxisAlignment,
          children: [
            Text(
              '校园',
              textAlign: layout.textAlign,
              style: TextStyle(
                fontSize: 26,
                height: 1.1,
                fontWeight: FontWeight.w900,
                color: tokens.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              semesterText,
              textAlign: layout.textAlign,
              style: TextStyle(
                fontSize: 12.5,
                color: tokens.textSecondary,
              ),
            ),
          ],
        );
        return AppCardSurface(
          blur: 0,
          surfaceOpacity: 1,
          themeArt: false,
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            color: tokens.card,
            borderRadius: BorderRadius.circular(shape.lg),
            border: Border.all(color: tokens.cardBorder),
          ),
          child: layout.alignment == 'center'
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    titleColumn,
                    const SizedBox(height: 8),
                    buildWeekBadge(opaqueCard: true, inline: true),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: layout.alignment == 'end'
                      ? [
                          buildWeekBadge(opaqueCard: true),
                          const SizedBox(width: 10),
                          Expanded(child: titleColumn),
                        ]
                      : [
                          Expanded(child: titleColumn),
                          const SizedBox(width: 10),
                          buildWeekBadge(opaqueCard: true),
                        ],
                ),
        );
      },
      compactInfoBuilder: (_, layout) {
        return AppCardSurface(
          blur: 0,
          surfaceOpacity: 1,
          themeArt: false,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: tokens.card,
            borderRadius: BorderRadius.circular(shape.lg),
            border: Border.all(color: tokens.cardBorder),
          ),
          child: Align(
            alignment: layout.boxAlignment,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: switch (layout.alignment) {
                'center' => WrapAlignment.center,
                'end' => WrapAlignment.end,
                _ => WrapAlignment.start,
              },
              children: [
                Text(
                  '校园',
                  style: AppThemeStyle.of(context).title(TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: tokens.textPrimary,
                  )),
                ),
                Text(
                  semesterText,
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.textSecondary,
                  ),
                ),
                buildWeekBadge(opaqueCard: true, inline: true),
              ],
            ),
          ),
        );
      },
    );
  }
}
