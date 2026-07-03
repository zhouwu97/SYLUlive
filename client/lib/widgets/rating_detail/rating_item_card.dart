import 'package:flutter/material.dart';

class RatingItemCard extends StatelessWidget {
  final String userName;
  final String comment;
  final int star;
  final bool isOwn;
  final VoidCallback? onLongPress;

  const RatingItemCard({
    super.key,
    required this.userName,
    required this.comment,
    required this.star,
    this.isOwn = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    final item = InkWell(
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: isDark ? Colors.white12 : Colors.grey.shade200,
                  child: Text(
                    userName.isNotEmpty ? userName[0] : '?',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    userName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
                Text(
                  '★' * star + '☆' * (5 - star),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.amber,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            if (comment.trim().isNotEmpty) ...[
              const SizedBox(height: 5),
              Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Text(
                  comment.trim(),
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    
    // Add a divider below the item
    return Column(
      children: [
        item,
        Divider(
          height: 1,
          thickness: 1,
          indent: 46,
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
        ),
      ],
    );
  }
}
