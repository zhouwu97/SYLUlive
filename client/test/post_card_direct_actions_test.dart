import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/widgets/post_card.dart';

class _CardAuthProvider extends ChangeNotifier implements AuthProvider {
  _CardAuthProvider({required this.client, required this.loggedIn});

  final Dio client;
  final bool loggedIn;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Post _post({int likeCount = 12, bool isLiked = false, int replyCount = 3}) {
  return Post(
    id: 1,
    title: '测试帖子',
    content: '测试内容',
    boardId: 1,
    authorId: 1,
    author: User(
      id: 1,
      studentId: '1',
      nickname: '作者',
      createdAt: DateTime(2026),
    ),
    createdAt: DateTime(2026, 8, 1),
    isLiked: isLiked,
    likeCount: likeCount,
    replyCount: replyCount,
  );
}

void main() {
  testWidgets('点击点赞立即 +1 且不进入详情', (tester) async {
    var onTapCount = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
                requestOptions: options, statusCode: 200, data: <dynamic>[]),
          );
        },
      ),
    );
    final auth = _CardAuthProvider(client: dio, loggedIn: true);
    final postProvider = PostProvider(dio, enableCache: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<PostProvider>.value(value: postProvider),
          ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<WaterSectionProvider>.value(
            value: WaterSectionProvider(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PostCard(post: _post(), onTap: () => onTapCount++),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('post-card-like')));
    await tester.pumpAndSettle();

    expect(find.text('13'), findsOneWidget);
    expect(onTapCount, 0, reason: '点赞不应进入详情');
  });

  testWidgets('点赞失败回滚原状态', (tester) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/posts/1/like') {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
            return;
          }
          handler.resolve(
            Response(
                requestOptions: options, statusCode: 200, data: <dynamic>[]),
          );
        },
      ),
    );
    final auth = _CardAuthProvider(client: dio, loggedIn: true);
    final postProvider = PostProvider(dio, enableCache: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<PostProvider>.value(value: postProvider),
          ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<WaterSectionProvider>.value(
            value: WaterSectionProvider(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: PostCard(post: _post())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('post-card-like')));
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget, reason: '失败应回滚到 12');
  });

  testWidgets('点击评论触发 onCommentTap 回调', (tester) async {
    Post? captured;
    final dio = Dio();
    final auth = _CardAuthProvider(client: dio, loggedIn: true);
    final postProvider = PostProvider(dio, enableCache: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<PostProvider>.value(value: postProvider),
          ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<WaterSectionProvider>.value(
            value: WaterSectionProvider(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: _post(),
              onCommentTap: (post) => captured = post,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('post-card-comment')));
    await tester.pumpAndSettle();

    expect(captured?.id, 1);
    expect(captured?.replyCount, 3);
  });

  testWidgets('未登录点赞提示登录且不改计数', (tester) async {
    final dio = Dio();
    final auth = _CardAuthProvider(client: dio, loggedIn: false);
    final postProvider = PostProvider(dio, enableCache: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<PostProvider>.value(value: postProvider),
          ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<WaterSectionProvider>.value(
            value: WaterSectionProvider(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: PostCard(post: _post())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('post-card-like')));
    await tester.pumpAndSettle();

    expect(find.text('请先登录'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('长按信息流正文复制完整内容且不进入详情', (tester) async {
    String? copiedText;
    var onTapCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final dio = Dio();
    final auth = _CardAuthProvider(client: dio, loggedIn: true);
    final postProvider = PostProvider(dio, enableCache: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<PostProvider>.value(value: postProvider),
          ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<WaterSectionProvider>.value(
            value: WaterSectionProvider(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PostCard(
              post: _post(),
              onTap: () => onTapCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('测试内容'));
    await tester.pump();

    expect(copiedText, '测试内容');
    expect(find.text('帖子正文已复制'), findsOneWidget);
    expect(onTapCount, 0);
  });
}
