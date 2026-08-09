import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
import 'campus_theme.dart';

class CampusHeader extends StatelessWidget {
  final String semester;

  const CampusHeader({super.key, required this.semester});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Calculate week number roughly or just hardcode as in example for visual
    // Note: We'll put a placeholder "第18周" or dynamic if available.
    // Here we can use date logic or just '第18周' for now.
    final now = DateTime.now();
    final dateStr = DateFormat('MM-dd').format(now);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      decoration: BoxDecoration(
        gradient: isDark
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [CampusTheme.darkCard, Color(0xFF172522)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Color(0xFFF1FBF7)],
              ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : CampusTheme.primary.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? Colors.black : CampusTheme.primary)
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
                    color: isDark ? Colors.white : const Color(0xFF20212B),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  semester, // Like "2025-2026 第二学期"
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: CampusTheme.subText,
                  ),
                ),
              ],
            ),
          ),
          // 右侧周次信息同时承担本学期进度提示。
          Container(
            width: 68,
            padding: const EdgeInsets.fromLTRB(7, 7, 7, 6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : CampusTheme.border,
              ),
            ),
            child: Column(
              children: [
                const Text(
                  '第18周', // TODO: 接入校历后替换为真实周次
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: CampusTheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateStr,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: CampusTheme.subText,
                  ),
                ),
                const SizedBox(height: 5),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 0.9),
                  duration: reduceMotion ? Duration.zero : AppMotion.page,
                  curve: AppMotion.standard,
                  builder: (context, progress, child) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: progress,
                        backgroundColor: CampusTheme.primary.withValues(
                          alpha: isDark ? 0.16 : 0.1,
                        ),
                        valueColor: const AlwaysStoppedAnimation(
                          CampusTheme.primary,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
