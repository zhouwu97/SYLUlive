import 'package:flutter/material.dart';

import '../models/post.dart';
import 'poll/poll_post_card.dart';
import 'post_card.dart';

class CommunityPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  final ValueChanged<int>? onAuthorTap;
  final ValueChanged<Post>? onPostUpdated;
  final bool disableAuthorNavigation;
  final PollCardVariant pollVariant;

  const CommunityPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onAuthorTap,
    this.onPostUpdated,
    this.disableAuthorNavigation = false,
    this.pollVariant = PollCardVariant.homeCompact,
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
      );
    }
    return PostCard(
      post: post,
      onTap: onTap,
      onAuthorTap: onAuthorTap,
      disableAuthorNavigation: disableAuthorNavigation,
    );
  }
}
