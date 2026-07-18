import 'package:flutter/material.dart';
import '../models/post.dart';
import '../screens/user_home_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/poll/poll_detail_screen.dart';

class AppNavigation {
  static Future<T?> openUserHome<T>(
    BuildContext context, {
    required int userId,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        settings: RouteSettings(name: '/user/$userId'),
        builder: (_) => UserHomeScreen(userId: userId),
      ),
    );
  }

  static Future<T?> openPostDetail<T>(
    BuildContext context, {
    required Post post,
    bool isMarket = false,
    int? sourceUserId,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        settings: RouteSettings(name: '/post/${post.id}'),
        builder: (detailContext) => _buildDetail(
          post,
          isMarket: isMarket,
          onAuthorTap: (authorId) {
            if (sourceUserId != null && authorId == sourceUserId) {
              return;
            }
            AppNavigation.openUserHome(detailContext, userId: authorId);
          },
        ),
      ),
    );
  }

  static Widget _buildDetail(
    Post post, {
    required bool isMarket,
    required ValueChanged<int> onAuthorTap,
  }) {
    if (post.isPoll) {
      return PollDetailScreen(
        pollId: post.pollMeta!.id,
        initialPost: post,
        onAuthorTap: onAuthorTap,
      );
    }
    return PostDetailScreen(
      postId: post.id,
      initialPost: post,
      isMarket: isMarket,
      onAuthorTap: onAuthorTap,
    );
  }
}
