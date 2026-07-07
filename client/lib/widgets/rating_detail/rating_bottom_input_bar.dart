import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingBottomInputBar extends StatelessWidget {
  final String hintText;
  final VoidCallback onTap;

  const RatingBottomInputBar({
    super.key,
    required this.hintText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 8 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: RankingTokens.cardBg(isDark),
        border: Border(
          top: BorderSide(
            color: RankingTokens.borderColor(isDark),
          ),
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : RankingTokens.pageBg(isDark),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 16,
                color: RankingTokens.subColor(isDark),
              ),
              const SizedBox(width: 8),
              Text(
                hintText,
                style: TextStyle(
                  fontSize: 13,
                  color: RankingTokens.subColor(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
