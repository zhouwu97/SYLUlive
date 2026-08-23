import 'package:flutter/material.dart';

import '../models/post.dart';
import '../screens/poll/poll_detail_screen.dart';
import '../screens/post_detail_screen.dart';

Route buildPostDetailRoute(
  Post post, {
  bool? isMarket,
  bool isDesktopSplitMode = false,
  bool hideBackButton = false,
  int? targetReplyId,
  ValueChanged<int>? onAuthorTap,
}) {
  // 回复通知等入口没有上下文参数时，按帖子所属板块选择详情布局。
  final resolvedIsMarket = isMarket ?? post.boardId == 2;
  return MaterialPageRoute(
    settings: RouteSettings(name: '/post/${post.id}'),
    builder: (_) => post.isPoll
        ? PollDetailScreen(
            pollId: post.pollMeta!.id,
            initialPost: post,
            isDesktopSplitMode: isDesktopSplitMode,
            hideBackButton: hideBackButton,
            onAuthorTap: onAuthorTap)
        : PostDetailScreen(
            postId: post.id,
            initialPost: post,
            targetReplyId: targetReplyId,
            isMarket: resolvedIsMarket,
            isDesktopSplitMode: isDesktopSplitMode,
            hideBackButton: hideBackButton,
            onAuthorTap: onAuthorTap),
  );
}
