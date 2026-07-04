import 'package:flutter/material.dart';

class LevelProgressPill extends StatelessWidget {
  final String levelLabel;
  final String? title;
  final String expText;
  final double progress;
  final Color accentColor;
  final bool darkOnImage;
  final bool isMaxLevel;
  final bool isLoggedIn;

  const LevelProgressPill({
    super.key,
    required this.levelLabel,
    this.title,
    required this.expText,
    required this.progress,
    required this.accentColor,
    this.darkOnImage = false,
    this.isMaxLevel = false,
    this.isLoggedIn = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final pillBgColor = darkOnImage
        ? Colors.black.withValues(alpha: 0.35)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.85));

    final pillBorderColor = accentColor.withValues(alpha: 0.15);
    final textColor = (darkOnImage || isDark) ? Colors.white : const Color(0xFF151922);
    final mutedTextColor = darkOnImage
        ? Colors.white70
        : (isDark ? Colors.white60 : const Color(0xFF60646C));
    final progressBgColor = accentColor.withValues(alpha: 0.15);

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: pillBgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: pillBorderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 14, color: accentColor),
          const SizedBox(width: 4),
          Text(
            levelLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: textColor,
            ),
          ),
          if (title != null && title!.isNotEmpty) ...[
            Text(
              ' · $title',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: mutedTextColor,
              ),
            ),
          ],
          const SizedBox(width: 10),
          if (!isLoggedIn) ...[
            Text(
              '登录后查看经验',
              style: TextStyle(
                fontSize: 11,
                color: mutedTextColor,
              ),
            ),
          ] else if (isMaxLevel) ...[
            Text(
              '已满级',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: mutedTextColor,
              ),
            ),
          ] else if (expText.isNotEmpty) ...[
            SizedBox(
              width: 50,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: progressBgColor,
                  valueColor: AlwaysStoppedAnimation(accentColor),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              expText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: mutedTextColor,
              ),
            ),
          ]
        ],
      ),
    );
  }
}
