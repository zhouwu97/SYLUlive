import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/screens/likes_received_screen.dart';
import 'package:shenliyuan/screens/browsing_history_screen.dart';
import 'package:shenliyuan/screens/social_list_screen.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/screens/ai/ai_feature_settings_screen.dart';
import 'package:shenliyuan/screens/ai/campus_personal_data_permission_screen.dart';

class SurfaceFixtureAuth extends AuthProvider {
  SurfaceFixtureAuth(super.dio) : super(loadStoredAuth: false);
  @override
  bool get isLoggedIn => true;
  @override
  User get user => User(
      id: 1, studentId: 'fixture', nickname: '本地验收', createdAt: DateTime(2026));
}

Map<String, dynamic> surfacePost({bool poll = false}) => {
      'id': poll ? 101 : 300,
      'title': poll ? '校园投票' : '校园生活',
      'content': '正文与评论各有连续底面。壁纸仍然保留在页面背景中。',
      'author_id': 2,
      'board_id': 1,
      'reply_count': poll ? 1 : 0,
      'author': {'id': 2, 'nickname': '测试作者', 'avatar': ''},
      'created_at': '2026-10-28T08:00:00Z',
      'images': <String>[],
      if (poll) ...{
        'post_type': 'poll',
        'content_kind': 'poll',
        'poll_meta': {
          'id': 101,
          'post_id': 101,
          'category': 'other',
          'selection_mode': 'single',
          'max_choices': 1,
          'results_visibility': 'always',
          'status': 'active',
          'effective_status': 'active',
          'participant_count': 2,
          'has_voted': true,
          'results_visible': true,
          'can_vote': false,
          'can_change': false,
          'is_owner': false,
          'remaining_seconds': 3600,
          'options': [
            {
              'id': 10,
              'text': '第一个选项',
              'sort_order': 0,
              'vote_count': 1,
              'ratio': .5
            },
            {
              'id': 11,
              'text': '第二个选项',
              'sort_order': 1,
              'vote_count': 1,
              'ratio': .5
            },
          ],
        },
      },
    };

Dio surfaceFixtureDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    final Object data;
    if (o.path == '/user/likes/received') {
      data = {
        'items': List.generate(
            5,
            (i) => {
                  'id': i + 1,
                  'user_id': i + 2,
                  'nickname': '同学${i + 1}',
                  'avatar': '',
                  'target_type': 'reply',
                  'target_id': 1,
                  'post_id': 300,
                  'post_title': '校园里的新鲜事',
                  'created_at': '2026-10-28T08:00:00Z',
                }),
        'has_more': false
      };
    } else if (o.path.endsWith('/following') || o.path.endsWith('/followers')) {
      data = {
        'items': [
          {
            'id': 2,
            'nickname': '测试同学',
            'avatar': '',
            'student_id': '',
            'created_at': '2026-01-01T00:00:00Z'
          }
        ],
        'total': 1
      };
    } else if (o.path == '/ai/personal-data-access') {
      data = {'permissions': []};
    } else if (o.path == '/polls/101') {
      data = surfacePost(poll: true);
    } else if (o.path.contains('/replies')) {
      data = {
        'replies': o.path.contains('/101/')
            ? [
                {
                  'id': 21,
                  'post_id': 101,
                  'author_id': 2,
                  'content': '评论内容应清晰可读，下方回复使用同一块底面。',
                  'created_at': '2026-10-28T08:00:00Z',
                  'author': {'id': 2, 'nickname': '测试同学', 'avatar': ''},
                }
              ]
            : [],
        'total': o.path.contains('/101/') ? 1 : 0
      };
    } else if (o.path == '/posts/300') {
      data = surfacePost();
    } else if (o.path.endsWith('/featured-application-status')) {
      data = {'has_pending': false};
    } else {
      h.reject(DioException(requestOptions: o, message: '未配置的本地请求'));
      return;
    }
    h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
  }));
  return dio;
}

Widget surfaceFixtureScene(String scene, Dio dio) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => SurfaceFixtureAuth(dio)),
        ChangeNotifierProvider(create: (_) => PollProvider(PollService(dio))),
        ChangeNotifierProvider(
            create: (_) => PostProvider(dio, enableCache: false)),
        ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
      ],
      child: switch (scene) {
        'likes' => const LikesReceivedScreen(),
        'history' => const BrowsingHistoryScreen(),
        'social' => const SocialListScreen(userId: 2),
        'flags' => const AIFeatureSettingsScreen(),
        'permissions' => CampusPersonalDataPermissionScreen(dio: dio),
        'poll' => const PollDetailScreen(pollId: 101),
        'post' => const PostDetailScreen(postId: 300),
        'market-detail' => const PostDetailScreen(postId: 300, isMarket: true),
        _ => throw ArgumentError.value(scene),
      },
    );
