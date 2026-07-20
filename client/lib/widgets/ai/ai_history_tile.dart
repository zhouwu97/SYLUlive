import 'package:flutter/material.dart';

import '../../models/ai_conversation.dart';

class AiHistoryTile extends StatelessWidget {
  final AiConversation conversation;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool isDeleting;

  const AiHistoryTile({
    super.key,
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    this.isDeleting = false,
  });

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(time.year, time.month, time.day);
    final diffDays = today.difference(date).inDays;

    if (diffDays == 0) {
      final hour = time.hour.toString().padLeft(2, '0');
      final minute = time.minute.toString().padLeft(2, '0');
      return '今天 $hour:$minute';
    } else if (diffDays == 1) {
      return '昨天';
    } else if (diffDays < 7) {
      return '$diffDays天前';
    } else if (now.year == time.year) {
      return '${time.month}月${time.day}日';
    } else {
      return '${time.year}年${time.month}月${time.day}日';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        decoration: BoxDecoration(
          color: isSelected ? colors.primaryContainer.withValues(alpha: 0.3) : Colors.transparent,
          border: isSelected
              ? Border(left: BorderSide(color: colors.primary, width: 2))
              : const Border(left: BorderSide(color: Colors.transparent, width: 2)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.forum_outlined, size: 20, color: colors.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.title.isEmpty ? '新会话' : conversation.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          conversation.lastMessagePreview.isEmpty ? '暂无消息' : conversation.lastMessagePreview,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conversation.updatedAt ?? conversation.createdAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                onPressed: isDeleting ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: colors.error,
                tooltip: '删除会话',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
