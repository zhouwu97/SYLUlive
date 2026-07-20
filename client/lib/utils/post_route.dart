import 'package:flutter/material.dart';

import '../models/post.dart';
import '../screens/poll/poll_detail_screen.dart';
import '../screens/post_detail_screen.dart';

Route buildPostDetailRoute(Post post, {bool isMarket = false, bool isDesktopSplitMode = false, bool hideBackButton = false, int? targetReplyId, ValueChanged<int>? onAuthorTap}) {
  return MaterialPageRoute(
    settings: RouteSettings(name: '/post/${post.id}'),
    builder: (_) => post.isPoll
        ? PollDetailScreen(pollId: post.pollMeta!.id, initialPost: post, isDesktopSplitMode: isDesktopSplitMode, hideBackButton: hideBackButton, onAuthorTap: onAuthorTap)
        : PostDetailScreen(postId: post.id, initialPost: post, targetReplyId: targetReplyId, isMarket: isMarket, isDesktopSplitMode: isDesktopSplitMode, hideBackButton: hideBackButton, onAuthorTap: onAuthorTap),
  );
}
