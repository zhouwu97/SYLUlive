import 'package:flutter/material.dart';

import '../app_action_popup_menu.dart';

/// 帖子卡片右上角操作（FEED-3）。
///
/// 别人的帖子：不感兴趣 / 不看TA / 举报
/// 自己的帖子：编辑 / 删除
/// P2 之前不出现「减少类似内容」。
enum FeedPostAction { notInterested, hideAuthor, report, edit, delete }

class FeedPostActionMenu extends StatelessWidget {
  const FeedPostActionMenu({
    super.key,
    required this.isMine,
    required this.isDark,
    required this.onAction,
  });

  final bool isMine;
  final bool isDark;
  final ValueChanged<FeedPostAction> onAction;

  @override
  Widget build(BuildContext context) {
    final entries = <Object>[
      if (isMine) ...[
        const AppPopupAction(
          value: 'edit',
          label: '编辑',
          icon: Icons.edit_outlined,
        ),
        const AppPopupAction(
          value: 'delete',
          label: '删除',
          icon: Icons.delete_outline_rounded,
          danger: true,
        ),
      ] else ...[
        const AppPopupAction(
          value: 'not_interested',
          label: '不感兴趣',
          icon: Icons.block_rounded,
        ),
        const AppPopupAction(
          value: 'hide_author',
          label: '不看 TA',
          icon: Icons.visibility_off_outlined,
        ),
        const Divider(),
        const AppPopupAction(
          value: 'report',
          label: '举报',
          icon: Icons.flag_outlined,
        ),
      ],
    ];

    return AppActionPopupMenu(
      icon: Icon(
        Icons.more_horiz_rounded,
        size: 20,
        color: isDark ? Colors.white54 : Colors.grey[500],
      ),
      entries: entries,
      onSelected: (value) => onAction(_fromValue(value)),
    );
  }

  static FeedPostAction _fromValue(String value) {
    switch (value) {
      case 'edit':
        return FeedPostAction.edit;
      case 'delete':
        return FeedPostAction.delete;
      case 'not_interested':
        return FeedPostAction.notInterested;
      case 'hide_author':
        return FeedPostAction.hideAuthor;
      case 'report':
      default:
        return FeedPostAction.report;
    }
  }
}
