import 'package:flutter/material.dart';

import '../models/post.dart';
import 'feed/feed_post_action_menu.dart';
import 'poll/poll_post_card.dart';
import 'post_card.dart';

class CommunityPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  final ValueChanged<int>? onAuthorTap;
  final ValueChanged<Post>? onPostUpdated;

  /// 评论按钮点击回调（透传给 PostCard）。
  final ValueChanged<Post>? onCommentTap;
  final bool disableAuthorNavigation;
  final PollCardVariant pollVariant;

  /// 卡片右上角操作菜单回调（FEED-3），透传给 PostCard / PollPostCard。
  final ValueChanged<FeedPostAction>? onPostAction;
  final bool allowNotInterested;
  final bool allowHideAuthor;
  final bool allowReport;

  const CommunityPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onAuthorTap,
    this.onPostUpdated,
    this.onCommentTap,
    this.disableAuthorNavigation = false,
    this.pollVariant = PollCardVariant.homeCompact,
    this.onPostAction,
    this.allowNotInterested = true,
    this.allowHideAuthor = true,
    this.allowReport = true,
  });

  @override
  Widget build(BuildContext context) {
    if (post.isPoll) {
      return PollPostCard(
        post: post,
        onTap: onTap,
        onAuthorTap: disableAuthorNavigation ? null : onAuthorTap,
        onPostUpdated: onPostUpdated,
        variant: pollVariant,
        onPostAction: onPostAction,
        allowNotInterested: allowNotInterested,
        allowHideAuthor: allowHideAuthor,
        allowReport: allowReport,
      );
    }
    return PostCard(
      post: post,
      onTap: onTap,
      onAuthorTap: onAuthorTap,
      onCommentTap: onCommentTap,
      disableAuthorNavigation: disableAuthorNavigation,
      onPostAction: onPostAction,
      allowNotInterested: allowNotInterested,
      allowHideAuthor: allowHideAuthor,
      allowReport: allowReport,
    );
  }
}
