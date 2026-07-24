import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingActionRow extends StatelessWidget {
  final bool isOwn;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote; // 'up', 'down', or null/'none'

  final VoidCallback? onHelpful;
  final VoidCallback? onUnhelpful;
  final VoidCallback? onReport;

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const RatingActionRow({
    super.key,
    required this.isOwn,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    this.myVote,
    this.onHelpful,
    this.onUnhelpful,
    this.onReport,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isOwn) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: onEdit,
            style: TextButton.styleFrom(
              foregroundColor: RankingTokens.subColor(isDark),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              minimumSize: const Size(0, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('编辑'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onDelete,
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              minimumSize: const Size(0, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('删除'),
          ),
        ],
      );
    }

    final hasVotedUp = myVote == 'up';
    final hasVotedDown = myVote == 'down';

    return Row(
      children: [
        _buildVoteButton(
          isDark: isDark,
          icon: Icons.thumb_up_alt_outlined,
          activeIcon: Icons.thumb_up_alt_rounded,
          label: '有用',
          count: helpfulCount,
          isActive: hasVotedUp,
          onTap: onHelpful,
        ),
        const SizedBox(width: 16),
        _buildVoteButton(
          isDark: isDark,
          icon: Icons.thumb_down_alt_outlined,
          activeIcon: Icons.thumb_down_alt_rounded,
          label: '没帮助',
          count: unhelpfulCount,
          isActive: hasVotedDown,
          onTap: onUnhelpful,
        ),
        const Spacer(),
        IconButton(
          onPressed: onReport,
          icon: const Icon(Icons.more_horiz),
          iconSize: 20,
          color: RankingTokens.mutedColor(isDark),
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ],
    );
  }

  Widget _buildVoteButton({
    required bool isDark,
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required int count,
    required bool isActive,
    required VoidCallback? onTap,
  }) {
    final activeColor = RankingTokens.titleColor(isDark);
    final inactiveColor = RankingTokens.mutedColor(isDark);
    final color = isActive ? activeColor : inactiveColor;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              count > 0 ? '$label $count' : label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
