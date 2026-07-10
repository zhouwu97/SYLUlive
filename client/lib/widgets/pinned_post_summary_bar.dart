import 'package:flutter/material.dart';
import '../models/post.dart';

class PinnedPostSummaryBar extends StatelessWidget {
  final List<Post> posts;
  final bool isDark;
  final ValueChanged<Post> onOpenPost;
  final String label;

  const PinnedPostSummaryBar({
    super.key,
    required this.posts,
    required this.isDark,
    required this.onOpenPost,
    this.label = '置顶',
  });

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) return const SizedBox.shrink();

    final first = posts.first;
    final title = first.title.trim().isNotEmpty
        ? first.title.trim()
        : first.content.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (posts.length == 1) {
            onOpenPost(first);
          } else {
            _showPinnedSheet(context);
          }
        },
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171B24) : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFEDEFF3),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFF7C5CE6)),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7C5CE6),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : const Color(0xFF8B8E98),
                  ),
                ),
              ),
              if (posts.length > 1) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFF5F6F8),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '共${posts.length}条',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color:
                              isDark ? Colors.white70 : const Color(0xFF222222),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF222222),
                      ),
                    ],
                  ),
                ),
              ] else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: isDark ? Colors.white38 : const Color(0xFFB2B5BD),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPinnedSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          itemCount: posts.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final post = posts[index];
            final title = post.title.trim().isNotEmpty
                ? post.title.trim()
                : post.content.trim();

            return ListTile(
              dense: true,
              leading: const Text(
                '置顶',
                style: TextStyle(
                  color: Color(0xFF7C5CE6),
                  fontWeight: FontWeight.w700,
                ),
              ),
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(context);
                onOpenPost(post);
              },
            );
          },
        );
      },
    );
  }
}
