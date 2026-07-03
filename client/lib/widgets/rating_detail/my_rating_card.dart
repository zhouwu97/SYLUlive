import 'package:flutter/material.dart';

class MyRatingCard extends StatelessWidget {
  final int currentStar;
  final String? currentComment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool isDeleting;

  const MyRatingCard({
    super.key,
    required this.currentStar,
    required this.currentComment,
    required this.onEdit,
    required this.onDelete,
    this.isDeleting = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? primaryColor.withValues(alpha: 0.2) : primaryColor.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的评价',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              if (isDeleting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: isDark ? Colors.white54 : Colors.black54, size: 20),
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text('修改评价'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('删除评价'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: isDark ? primaryColor.withValues(alpha: 0.2) : primaryColor.withValues(alpha: 0.1),
                child: Text(
                  '我',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : primaryColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '我',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '★' * currentStar + '☆' * (5 - currentStar),
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.amber,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${currentStar.toDouble()}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ],
          ),
          if (currentComment != null && currentComment!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              currentComment!.trim(),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
