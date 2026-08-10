import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';

class _AuthProvider extends ChangeNotifier implements AuthProvider {
  _AuthProvider({required this.client});

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
    'id': 100,
    'title': '测试帖子',
    'content': '测试内容',
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-08-01T00:00:00Z',
    'is_liked': false,
    'like_count': 12,
  };
}

Dio _detailDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.path;
        if (path == '/posts/100') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _postJson(),
            ),
          );
          return;
        }
        if (path == '/posts/100/replies') {
          handler.resolve(
            Response(
                requestOptions: options, statusCode: 200, data: <dynamic>[]),
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

Widget _app(Post? initialPost, {required bool focusReplyComposer}) {
  final dio = _detailDio();
  final auth = _AuthProvider(client: dio);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<PostProvider>.value(
        value: PostProvider(dio, enableCache: false),
      ),
      ChangeNotifierProvider<ThemeProvider>.value(
        value: ThemeProvider(loadOnStart: false),
      ),
    ],
    child: MaterialApp(
      home: PostDetailScreen(
        postId: 100,
        initialPost: initialPost,
        focusReplyComposer: focusReplyComposer,
      ),
    ),
  );
}

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('focusReplyComposer=true 时评论输入框展开并获得焦点', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '测试内容',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(_app(initial, focusReplyComposer: true));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('post-reply-input'));
    expect(input, findsOneWidget, reason: '评论输入框应展开');
    final field = tester.widget<TextField>(input);
    expect(field.focusNode?.hasFocus, isTrue, reason: '评论输入框应获得焦点');
  });

  testWidgets('focusReplyComposer=false 时评论输入框不自动展开', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '测试内容',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(_app(initial, focusReplyComposer: false));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('post-reply-input')),
      findsNothing,
      reason: '默认进入详情不应自动展开输入框',
    );
  });

  testWidgets('详情页点赞成功后与 Feed 信息流状态一致', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '测试内容',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(_app(initial, focusReplyComposer: false));
    await tester.pumpAndSettle();

    expect(find.text('12'), findsWidgets);
    // 点击详情页点赞按钮（composer 收起态下方的点赞统计）。
    await tester.tap(
      find.descendant(
        of: find.byType(PostReplyComposer),
        matching: find.byIcon(Icons.thumb_up_outlined),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('13'), findsWidgets);
  });
}
