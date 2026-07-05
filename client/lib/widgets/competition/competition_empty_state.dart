import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class CompetitionEmptyState extends StatelessWidget {
  final VoidCallback onAiImport;
  final VoidCallback onCreate;
  final String title;
  final String message;
  final String primaryText;
  final String secondaryText;

  const CompetitionEmptyState({
    super.key,
    required this.onAiImport,
    required this.onCreate,
    this.title = '还没有官方比赛',
    this.message = '先导入一批比赛，或手动创建',
    this.primaryText = 'AI导入',
    this.secondaryText = '新建比赛',
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: CompetitionUiTokens.pagePadding, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 42,
            color: CompetitionUiTokens.subColor(isDark).withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: CompetitionUiTokens.subColor(isDark),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(
                onPressed: onAiImport,
                style: FilledButton.styleFrom(
                  backgroundColor: CompetitionUiTokens.accent(isDark),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
                  ),
                ),
                child: Text(
                  primaryText,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: onCreate,
                style: OutlinedButton.styleFrom(
                  foregroundColor: CompetitionUiTokens.titleColor(isDark),
                  side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
                  ),
                ),
                child: Text(
                  secondaryText,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
