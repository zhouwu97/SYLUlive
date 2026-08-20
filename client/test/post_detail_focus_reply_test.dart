import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';

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

Map<String, dynamic> _postJson({String content = '测试内容'}) {
  return {
    'id': 100,
    'title': '测试帖子',
    'content': content,
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-08-01T00:00:00Z',
    'is_liked': false,
    'like_count': 12,
  };
}

Dio _detailDio({
  List<Map<String, dynamic>> replies = const [],
  String postContent = '测试内容',
}) {
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
              data: _postJson(content: postContent),
            ),
          );
          return;
        }
        if (path == '/posts/100/replies') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'replies': replies,
                'total': replies.length,
                'next_cursor': '',
              },
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

Widget _app(
  Post? initialPost, {
  required bool focusReplyComposer,
  List<Map<String, dynamic>> replies = const [],
  String postContent = '测试内容',
}) {
  final dio = _detailDio(replies: replies, postContent: postContent);
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

  testWidgets('点击评论回复不重置详情滚动位置', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: List.filled(90, '这是一段用于撑开帖子详情滚动区域的测试内容。').join('\n'),
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(
      _app(
        initial,
        focusReplyComposer: false,
        postContent: initial.content,
        replies: [
          {
            'id': 7,
            'post_id': 100,
            'author_id': 2,
            'author': {
              'id': 2,
              'student_id': '2',
              'nickname': '评论用户',
              'created_at': '2026-08-01T00:00:00Z',
            },
            'content': '可点击回复的评论',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    final scrollView = find.byKey(const ValueKey('post-detail-scroll-view'));
    await tester.drag(scrollView, const Offset(0, -5000));
    await tester.pumpAndSettle();

    double scrollOffset() {
      final scrollable = find.descendant(
        of: scrollView,
        matching: find.byType(Scrollable),
      );
      return tester.state<ScrollableState>(scrollable).position.pixels;
    }

    final before = scrollOffset();
    expect(before, greaterThan(0));

    await tester.tap(find.text('可点击回复的评论'));
    await tester.pumpAndSettle();

    expect(scrollOffset(), closeTo(before, 0.5));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('post-reply-input')),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('键盘弹出后评论输入框保持在键盘上方', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.tap(input);
    await tester.pump();

    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    await tester.pump();

    final inputRect = tester.getRect(input);
    expect(inputRect.bottom, lessThanOrEqualTo(450.5));
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

  testWidgets('focusReplyComposer=false 时评论输入框显示但不自动聚焦', (tester) async {
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

    final input = find.byKey(const ValueKey('post-reply-input'));
    expect(input, findsOneWidget, reason: '评论输入框应始终显示');
    final field = tester.widget<TextField>(input);
    expect(field.focusNode?.hasFocus, isFalse, reason: '默认进入详情不应自动聚焦');
  });

  testWidgets('输入状态下点击正文会收起键盘并保留草稿', (tester) async {
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
    await tester.enterText(input, '保留这段草稿');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('post-detail-input-dismiss-layer')),
      findsOneWidget,
    );

    await tester.tapAt(tester.getCenter(find.text('测试内容')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(input);
    expect(field.focusNode?.hasFocus, isFalse);
    expect(field.controller?.text, '保留这段草稿');
    expect(
      find.byKey(const ValueKey('post-detail-input-dismiss-layer')),
      findsOneWidget,
    );
  });

  testWidgets('表情面板打开时点击内容区会退出输入状态', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPanel), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('测试内容')));
    await tester.pumpAndSettle();

    expect(find.byType(AppEmojiPanel), findsNothing);
    expect(
      find.byKey(const ValueKey('post-detail-input-dismiss-layer')),
      findsOneWidget,
    );
  });

  testWidgets('输入时首次点击图片只收起输入，再次点击才预览', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '测试内容',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
      images: [
        PostImage(
          id: 1,
          postId: 100,
          fileId: 1,
          mediumUrl: 'http://example.com/post.png',
          originUrl: 'http://example.com/post.png',
        ),
      ],
    );

    await tester.pumpWidget(_app(initial, focusReplyComposer: true));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('post-reply-input'));
    final image = find.byKey(const ValueKey('single-post-image-tap-target'));
    expect(image, findsOneWidget);

    await tester.tapAt(tester.getCenter(image));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerScreen), findsNothing);
    expect(tester.widget<TextField>(input).focusNode?.hasFocus, isFalse);

    await tester.tapAt(tester.getCenter(image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ImageViewerScreen), findsOneWidget);
  });

  testWidgets('输入激活时右上角更多菜单仍可直接操作', (tester) async {
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

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('编辑帖子'), findsOneWidget);
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
    // 底部评论栏不再重复展示统计，使用帖子内容区的点赞入口。
    await tester.tap(find.byIcon(Icons.thumb_up_outlined).first);
    await tester.pumpAndSettle();

    expect(find.text('13'), findsWidgets);
  });
}
