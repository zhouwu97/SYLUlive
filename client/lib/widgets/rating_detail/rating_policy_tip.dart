import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingPolicyTip extends StatelessWidget {
  final String text;
  final RatingPolicyType type;

  const RatingPolicyTip({
    super.key,
    required this.text,
    this.type = RatingPolicyType.info,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isWarning = type == RatingPolicyType.warning;
    final Color bgColor = isWarning
        ? RankingTokens.warningColor(isDark)
            .withValues(alpha: isDark ? 0.12 : 0.08)
        : (isDark
            ? Colors.white.withValues(alpha: 0.04)
            : const Color(0xFFF7F8FC));
    final IconData iconData =
        isWarning ? Icons.warning_amber_rounded : Icons.info_outline_rounded;
    final Color iconColor = isWarning
        ? RankingTokens.warningColor(isDark)
        : RankingTokens.subColor(isDark);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: isWarning
            ? Border.all(
                color:
                    RankingTokens.warningColor(isDark).withValues(alpha: 0.18),
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(iconData, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: RankingTokens.subColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum RatingPolicyType {
  info,
  warning,
}
