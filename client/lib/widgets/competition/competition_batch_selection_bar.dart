import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class CompetitionBatchSelectionBar extends StatelessWidget {
  final int selectedCount;
  final bool allItemsSelected;
  final String allItemsLabel;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onActionClick;
  final VoidCallback onCancel;

  const CompetitionBatchSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allItemsSelected,
    required this.allItemsLabel,
    required this.onToggleSelectAll,
    required this.onActionClick,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = CompetitionUiTokens.primary(isDark);
    final bg = CompetitionUiTokens.cardBg(isDark);
    final border = CompetitionUiTokens.borderColor(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);
    
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, color: titleColor),
            onPressed: onCancel,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已选 $selectedCount 项',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
                InkWell(
                  onTap: onToggleSelectAll,
                  child: Text(
                    allItemsSelected ? '清除选择' : allItemsLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: selectedCount > 0 ? onActionClick : null,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('操作'),
            style: FilledButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
        ],
      ),
    );
  }
}
