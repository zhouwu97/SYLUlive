import 'package:flutter/material.dart';
import '../models/post.dart';
import '../screens/course_schedule_screen.dart';
import '../screens/user_home_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/poll/poll_detail_screen.dart';
import '../widgets/global_background_wrapper.dart';

class AppNavigation {
  /// 课表页面依赖外层背景壳，所有“从页面进入课表”的导航都走这里。
  /// 根 Tab 的课表由 HomeScreen 直接渲染，不应调用此 push helper。
  static Future<T?> openTimetable<T>(BuildContext context) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(
        settings: const RouteSettings(name: '/timetable'),
        builder: (_) => buildTimetablePage(),
      ),
    );
  }

  /// 正式路由与页面内入口共用同一套课表壳，避免透明 Scaffold 落到黑色
  /// Material 背景上。
  static Widget buildTimetablePage() {
    return const PredictiveBackGate(
      child: GlobalBackgroundWrapper(child: CourseScheduleScreen()),
    );
  }

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
