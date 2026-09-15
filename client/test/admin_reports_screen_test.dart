import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_reports_screen.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  _FakeAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user =>
      User(id: 1, studentId: '1', nickname: '测试', createdAt: DateTime(2026));

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, dynamic> _postJson() {
  return {
    'id': 408,
    'title': '测试帖子',
    'content': '帖子正文',
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-08-01T00:00:00Z',
    'is_liked': false,
    'like_count': 0,
  };
}

Map<String, dynamic> _reportJson({
  required int id,
  required String targetType,
  required int targetId,
  required String status,
  Map<String, dynamic>? snapshot,
}) {
  return {
    'id': id,
    'reporter_id': 2,
    'target_type': targetType,
    'target_id': targetId,
    'reason_code': 'fake',
    'reason': '举报理由',
    'status': status,
    if (snapshot != null) 'target_snapshot': jsonEncode(snapshot),
    'reporter': {
      'id': 2,
      'student_id': '2',
      'nickname': '举报人',
      'created_at': '2026-08-01T00:00:00Z',
    },
  };
}

Dio _reportsDio(List<Map<String, dynamic>> reports) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.path;
        if (path == '/reports') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: reports,
            ),
          );
          return;
        }
        if (path.startsWith('/posts/408/replies')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'replies': <dynamic>[],
                'total': 0,
                'next_cursor': '',
              },
            ),
          );
          return;
        }
        if (path.startsWith('/posts/408')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _postJson(),
            ),
          );
          return;
        }
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: <dynamic>{}),
        );
      },
    ),
  );
  return dio;
}

Widget _app(Dio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: _FakeAuthProvider(client: dio),
      ),
      ChangeNotifierProvider<PostProvider>.value(
        value: PostProvider(dio, enableCache: false),
      ),
      ChangeNotifierProvider<ThemeProvider>.value(
        value: ThemeProvider(loadOnStart: false),
      ),
    ],
    child: const MaterialApp(home: AdminReportsScreen()),
  );
}

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('帖子举报展示快照内容并跳转帖子详情', (tester) async {
    final dio = _reportsDio([
      _reportJson(
        id: 1,
        targetType: 'post',
        targetId: 408,
        status: 'pending',
        snapshot: {
          'title': '被举报的标题',
          'content': '被举报的正文',
          'image_file_ids': <int>[],
        },
      ),
    ]);
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.text('帖子 #408'), findsOneWidget);
    expect(find.textContaining('被举报的标题'), findsOneWidget);
    expect(find.textContaining('被举报的正文'), findsOneWidget);

    await tester.tap(find.textContaining('被举报的正文'));
    await tester.pumpAndSettle();

    expect(find.byType(PostDetailScreen), findsOneWidget);
    final detail = tester.widget<PostDetailScreen>(
      find.byType(PostDetailScreen),
    );
    expect(detail.postId, 408);
  });

  testWidgets('评论举报根据快照 post_id 跳转并定位评论', (tester) async {
    final dio = _reportsDio([
      _reportJson(
        id: 2,
        targetType: 'reply',
        targetId: 77,
        status: 'pending',
        snapshot: {
          'content': '被举报的评论',
          'post_id': 408,
          'image_file_ids': <int>[],
        },
      ),
    ]);
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.text('评论 #77'), findsOneWidget);

    await tester.tap(find.textContaining('被举报的评论'));
    await tester.pumpAndSettle();

    expect(find.byType(PostDetailScreen), findsOneWidget);
    final detail = tester.widget<PostDetailScreen>(
      find.byType(PostDetailScreen),
    );
    expect(detail.postId, 408);
    expect(detail.targetReplyId, 77);
  });

  testWidgets('食堂评价举报仅展示内容预览不跳转', (tester) async {
    final dio = _reportsDio([
      _reportJson(
        id: 3,
        targetType: 'canteen_rating',
        targetId: 9,
        status: 'pending',
        snapshot: {'star': 4, 'comment': '太难吃'},
      ),
    ]);
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.textContaining('评分：4'), findsOneWidget);
    expect(find.textContaining('太难吃'), findsOneWidget);

    await tester.tap(find.textContaining('太难吃'));
    await tester.pump();

    expect(find.byType(PostDetailScreen), findsNothing);
  });
}
