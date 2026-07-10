import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class CompetitionBatchConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final bool isDanger;

  const CompetitionBatchConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    this.isDanger = false,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String content,
    String confirmLabel = '确定',
    bool isDanger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => CompetitionBatchConfirmDialog(
        title: title,
        content: content,
        confirmLabel: confirmLabel,
        isDanger: isDanger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = CompetitionUiTokens.cardBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);
    final dangerColor = CompetitionUiTokens.dangerColor(isDark);
    final primaryColor = CompetitionUiTokens.accent(isDark);

    return AlertDialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: titleColor,
        ),
      ),
      content: Text(
        content,
        style: TextStyle(
          fontSize: 15,
          color: titleColor.withValues(alpha: 0.8),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            '取消',
            style: TextStyle(
              color: titleColor.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: isDanger ? dangerColor : primaryColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
