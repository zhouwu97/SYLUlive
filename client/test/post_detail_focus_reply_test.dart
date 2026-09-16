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
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
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
  bool scrollToReplies = false,
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
        scrollToReplies: scrollToReplies,
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
      // SelectableText 内部也有用于 selection overlay 的 Scrollable；详情
      // 页真正可滚动的容器位于匹配结果首位。
      return tester.state<ScrollableState>(scrollable.first).position.pixels;
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

  testWidgets('从评论回复入口打开键盘时，输入框逐帧保持在键盘上方', (tester) async {
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

    await tester.pumpWidget(
      _app(
        initial,
        focusReplyComposer: false,
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
            'content': '用于打开回复输入的评论',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.tap(find.text('用于打开回复输入的评论'));
    await tester.pump();

    for (final inset in [40.0, 160.0, 350.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));

      final inputRect = tester.getRect(input);
      expect(inputRect.bottom, lessThanOrEqualTo(800 - inset + 0.5));
    }
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

  testWidgets('评论入口只滚到评论区，不自动打开评论输入框', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: List.filled(90, '用于撑开详情滚动区域的正文。').join('\n'),
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
        scrollToReplies: true,
        postContent: initial.content,
        replies: [
          {
            'id': 7,
            'post_id': 100,
            'author_id': 2,
            'content': '用于验证评论区定位的评论',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    final scrollView = find.byKey(const ValueKey('post-detail-scroll-view'));
    final scrollable = find.descendant(
      of: scrollView,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;

    expect(position.pixels, greaterThan(0));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('post-reply-input')))
          .focusNode
          ?.hasFocus,
      isFalse,
    );
  });

  testWidgets('评论输入激活后向下滑动可收起键盘并保留草稿', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: List.filled(90, '用于撑开详情滚动区域的正文。').join('\n'),
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(
      _app(
        initial,
        focusReplyComposer: true,
        postContent: initial.content,
      ),
    );
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.enterText(input, '保留这段评论草稿');
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    final scrollView = find.byKey(const ValueKey('post-detail-scroll-view'));
    final scrollStart = tester.getCenter(scrollView);
    final upwardGesture = await tester.startGesture(scrollStart);
    await upwardGesture.moveBy(const Offset(0, -240));
    await upwardGesture.up();
    await tester.pump();
    final downwardGesture = await tester.startGesture(scrollStart);
    await downwardGesture.moveBy(const Offset(0, 20));
    await downwardGesture.moveBy(const Offset(0, 70));
    await downwardGesture.up();
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(input);
    expect(field.focusNode?.hasFocus, isFalse);
    expect(field.controller?.text, '保留这段评论草稿');
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

  testWidgets('输入未激活时不暴露收起输入的无障碍语义', (tester) async {
    ExcludeSemantics dismissSemantics() {
      return tester.widget<ExcludeSemantics>(
        find.ancestor(
          of: find.byKey(
            const ValueKey('post-detail-input-dismiss-layer'),
          ),
          matching: find.byType(ExcludeSemantics),
        ),
      );
    }

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
    expect(dismissSemantics().excluding, isTrue);

    await tester.tap(find.byKey(const ValueKey('post-reply-input')));
    await tester.pump();
    expect(dismissSemantics().excluding, isFalse);

    await tester.tapAt(tester.getCenter(find.text('测试内容')));
    await tester.pumpAndSettle();
    expect(dismissSemantics().excluding, isTrue);
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

  testWidgets('键盘收起归零后首次点击评论直接打开回复并聚焦', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '正文内容',
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
            'content': '测试评论项',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 1. 点击输入框激活输入
    await tester.tap(find.byKey(const ValueKey('post-reply-input')));
    await tester.pump();
    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));
    expect(composer.controller.focusNode.hasFocus, isTrue);

    // 2. 模拟系统弹出键盘
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(composer.controller.keyboardInset, 300);

    // 3. 模拟系统键盘收起（返回键/手势）
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();

    // 键盘收起到 0 后，stale focus 被清理，输入状态结束
    expect(composer.controller.keyboardInset, 0);
    expect(composer.controller.focusNode.hasFocus, isFalse);
    expect(composer.controller.isOpen, isFalse);

    // 4. 首次点击评论项，验证无需点第二次即可直接打开回复
    await tester.tap(find.text('测试评论项'));
    await tester.pumpAndSettle();

    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.focusNode.hasFocus, isTrue);
    expect(composer.controller.parentReplyId, 7);
  });

  testWidgets('回复评论A时直接点击评论B不被遮罩拦截且直接切换回复对象', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '正文内容',
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
        replies: [
          {
            'id': 101,
            'post_id': 100,
            'author_id': 11,
            'author': {
              'id': 11,
              'student_id': '11',
              'nickname': '用户甲',
              'created_at': '2026-08-01T00:00:00Z',
            },
            'content': '评论内容甲',
            'created_at': '2026-08-01T00:00:00Z',
          },
          {
            'id': 102,
            'post_id': 100,
            'author_id': 22,
            'author': {
              'id': 22,
              'student_id': '22',
              'nickname': '用户乙',
              'created_at': '2026-08-01T00:00:00Z',
            },
            'content': '评论内容乙',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));

    // 1. 点击评论甲，锁定回复对象甲
    await tester.tap(find.text('评论内容甲'));
    await tester.pumpAndSettle();

    expect(composer.controller.replyToUserId, 11);
    expect(composer.controller.replyToName, '用户甲');
    expect(composer.controller.parentReplyId, 101);
    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.focusNode.hasFocus, isTrue);

    // 2. 键盘处于打开状态下，直接点击评论乙
    await tester.tap(find.text('评论内容乙'));
    await tester.pumpAndSettle();

    // 点击未被遮罩吃掉，单次点击直接切换至用户乙且保持焦点打开
    expect(composer.controller.replyToUserId, 22);
    expect(composer.controller.replyToName, '用户乙');
    expect(composer.controller.parentReplyId, 102);
    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.focusNode.hasFocus, isTrue);
  });

  testWidgets('键盘打开状态下向下拖拽35px不会误收起输入框（消除双重累计）', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: List.filled(90, '用于撑开详情滚动区域的正文。').join('\n'),
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(
      _app(
        initial,
        focusReplyComposer: true,
        postContent: initial.content,
      ),
    );
    await tester.pumpAndSettle();

    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));
    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.focusNode.hasFocus, isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    final scrollView = find.byKey(const ValueKey('post-detail-scroll-view'));
    final scrollStart = tester.getCenter(scrollView);

    // 先向上滚动一部分距离
    final upwardGesture = await tester.startGesture(scrollStart);
    await upwardGesture.moveBy(const Offset(0, -240));
    await upwardGesture.up();
    await tester.pump();

    // 向下移动 35px（位于此前双重累计最易误触的 30~40px 区间）
    final downwardGesture = await tester.startGesture(scrollStart);
    await downwardGesture.moveBy(const Offset(0, 35));
    await downwardGesture.up();
    await tester.pump();

    // 验证去除 Listener.onPointerMove 重复累计后，35px 不会触发收起
    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.focusNode.hasFocus, isTrue);
  });

  testWidgets('键盘打开状态下向下真实拖拽70px收起输入框并保留草稿', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: List.filled(90, '用于撑开详情滚动区域的正文。').join('\n'),
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 1),
      isLiked: false,
      likeCount: 12,
    );

    await tester.pumpWidget(
      _app(
        initial,
        focusReplyComposer: true,
        postContent: initial.content,
      ),
    );
    await tester.pumpAndSettle();

    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));
    await tester.enterText(
      find.byKey(const ValueKey('post-reply-input')),
      '70px拖拽测试草稿',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    final scrollView = find.byKey(const ValueKey('post-detail-scroll-view'));
    final scrollStart = tester.getCenter(scrollView);

    // 先向上滚动一部分距离
    final upwardGesture = await tester.startGesture(scrollStart);
    await upwardGesture.moveBy(const Offset(0, -240));
    await upwardGesture.up();
    await tester.pump();

    // 向下真实拖动超过 56px（突破 touch slop 后拖动 70px）
    final downwardGesture = await tester.startGesture(scrollStart);
    await downwardGesture.moveBy(const Offset(0, 20));
    await downwardGesture.moveBy(const Offset(0, 70));
    await downwardGesture.up();
    await tester.pumpAndSettle();

    expect(composer.controller.isOpen, isFalse);
    expect(composer.controller.focusNode.hasFocus, isFalse);
    expect(composer.controller.textController.text, '70px拖拽测试草稿');
  });

  testWidgets('键盘手动收起到0残留焦点时重新openReply重新激活焦点', (tester) async {
    final initial = Post(
      id: 100,
      title: '测试帖子',
      content: '正文内容',
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
        replies: [
          {
            'id': 88,
            'post_id': 100,
            'author_id': 8,
            'author': {
              'id': 8,
              'student_id': '8',
              'nickname': '测试人员',
              'created_at': '2026-08-01T00:00:00Z',
            },
            'content': '测试焦点重新激活',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ],
      ),
    );
    await tester.pumpAndSettle();

    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));

    // 手动制造 keyboardInset == 0 且 focusNode.hasFocus == true 的竞态环境
    composer.controller.focusNode.requestFocus();
    await tester.pump();
    expect(composer.controller.focusNode.hasFocus, isTrue);
    expect(composer.controller.keyboardInset, 0);

    // 调用 openReply
    composer.controller.openReply(
      parentReplyId: 88,
      replyToUserId: 8,
      replyToName: '测试人员',
    );
    // 等待 layout 和下一帧 requestFocus
    await tester.pumpAndSettle();

    expect(composer.controller.focusNode.hasFocus, isTrue);
    expect(composer.controller.isOpen, isTrue);
    expect(composer.controller.parentReplyId, 88);
  });

  testWidgets('详情页中表情面板与键盘交接流畅且不发生塌陷', (tester) async {
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

    final composer =
        tester.widget<PostReplyComposer>(find.byType(PostReplyComposer));

    // 1. 打开表情面板
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pumpAndSettle();

    expect(composer.controller.showEmojiPanel, isTrue);
    expect(find.byType(AppEmojiPanel), findsOneWidget);

    // 2. 再次点击表情按钮切换回键盘（触发 handoff）
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();

    // 进入 handoff，表情面板在交接完成前保持可见
    expect(composer.controller.inputHandoffActive, isTrue);
    expect(composer.controller.showEmojiPanel, isTrue);

    // 等待交接保护期完成
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(composer.controller.inputHandoffActive, isFalse);
    expect(composer.controller.showEmojiPanel, isFalse);
    expect(composer.controller.bottomPanel, PostReplyBottomPanel.keyboard);
  });
}

