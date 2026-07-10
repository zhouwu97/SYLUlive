import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class CompetitionBatchAction {
  final String value;
  final String label;
  final IconData icon;
  final bool danger;

  const CompetitionBatchAction({
    required this.value,
    required this.label,
    required this.icon,
    this.danger = false,
  });
}

class CompetitionBatchActionSheet extends StatelessWidget {
  final int selectedCount;
  final List<CompetitionBatchAction> actions;
  final ValueChanged<String> onActionSelected;

  const CompetitionBatchActionSheet({
    super.key,
    required this.selectedCount,
    required this.actions,
    required this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);
    final dangerColor = CompetitionUiTokens.dangerColor(isDark);
    final primaryColor = CompetitionUiTokens.accent(isDark);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  '批量操作',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '已选择 $selectedCount 项',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: primaryColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...actions.map((action) =>
              _buildActionTile(context, action, titleColor, dangerColor)),
          const SizedBox(height: 8),
          Divider(color: Colors.grey.withValues(alpha: 0.2)),
          ListTile(
            title: const Center(
              child: Text(
                '取消',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile(BuildContext context, CompetitionBatchAction action,
      Color titleColor, Color dangerColor) {
    final color = action.danger ? dangerColor : titleColor;
    return ListTile(
      leading: Icon(action.icon, color: color),
      title: Text(
        action.label,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: action.danger ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      onTap: () {
        Navigator.pop(context);
        onActionSelected(action.value);
      },
    );
  }
}
