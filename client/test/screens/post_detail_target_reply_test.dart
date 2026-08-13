import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

final List<int> transparentImage = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _MockHttpClientResponse extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => transparentImage.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream.value(transparentImage).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

class _MockHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();
}

class _MockHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();
  @override
  void close({bool force = false}) {}
}

class _MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient();
  }
}

Map<String, dynamic> _postJsonWithImages({
  required int id,
  required String title,
  required List<String> imageUrls,
}) {
  return {
    "id": id,
    "title": title,
    "content": "Content",
    "board_id": 1,
    "author_id": 1,
    "author": {
      "id": 1,
      "nickname": "TestUser",
      "avatar": "http://example.com/avatar.png",
      "student_id": "123",
      "created_at": "2026-01-01T00:00:00.000Z",
    },
    "created_at": "2026-01-01T00:00:00.000Z",
    "images": [
      for (var index = 0; index < imageUrls.length; index++)
        {
          "id": index + 1,
          "post_id": id,
          "file_id": index + 1,
          "sort_order": index,
          "file": {
            "id": index + 1,
            "hash": "image_$index",
            "path": imageUrls[index],
            "size": 1,
            "mime_type": "image/png",
          },
        },
    ],
  };
}

Post _postWithImages({
  required int id,
  required String title,
  required List<String> imageUrls,
}) {
  return Post.fromJson(
    _postJsonWithImages(id: id, title: title, imageUrls: imageUrls),
  );
}

class FakeDio extends Fake implements Dio {
  /// children 懒加载接口被调用的次数（51-children 死锁回归测试用）。
  static int childrenRequestCount = 0;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    if (path.startsWith('/posts/104/replies') ||
        path.startsWith('/posts/105/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        } as dynamic,
      );
    } else if (path.startsWith('/posts/104') || path.startsWith('/posts/105')) {
      final hasContact = path.startsWith('/posts/104');
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'id': hasContact ? 104 : 105,
          'title': '集市商品',
          'content': '商品描述',
          'board_id': 2,
          'author_id': 2,
          'post_type': 'sell',
          'contact_type': hasContact ? 'wechat' : '',
          'contact': hasContact ? 'secret_wx_123' : '',
          'view_count': 5,
          'author': {
            'id': 2,
            'nickname': '卖家昵称很长用于窄屏测试',
            'avatar': '',
            'student_id': 'seller',
            'credit_score': 100,
            'created_at': '2026-01-01T00:00:00.000Z',
          },
          'created_at': '2026-07-18T00:00:00.000Z',
          'images': <dynamic>[],
        } as dynamic,
      );
    }
    if (path.startsWith('/posts/102/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        } as dynamic,
      );
    } else if (path.startsWith('/posts/102')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: _postJsonWithImages(
          id: 102,
          title: 'Single image',
          imageUrls: ['http://example.com/one.png'],
        ) as dynamic,
      );
    }
    if (path.startsWith('/posts/103/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        } as dynamic,
      );
    } else if (path.startsWith('/posts/103')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: _postJsonWithImages(
          id: 103,
          title: 'Two images',
          imageUrls: [
            'http://example.com/one.png',
            'http://example.com/two.png',
          ],
        ) as dynamic,
      );
    }
    if (path.startsWith('/posts/101/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        } as dynamic,
      );
    } else if (path.startsWith('/posts/101')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          "id": 101,
          "title": "Three images",
          "content": "Content",
          "board_id": 1,
          "author_id": 1,
          "created_at": "2026-01-01T00:00:00.000Z",
          "images": [
            {
              "id": 1,
              "post_id": 101,
              "file_id": 1,
              "sort_order": 0,
              "file": {
                "id": 1,
                "hash": "a",
                "path": "http://example.com/one.png",
                "size": 1,
                "mime_type": "image/png"
              }
            },
            {
              "id": 2,
              "post_id": 101,
              "file_id": 2,
              "sort_order": 1,
              "file": {
                "id": 2,
                "hash": "b",
                "path": "http://example.com/two.png",
                "size": 1,
                "mime_type": "image/png"
              }
            },
            {
              "id": 3,
              "post_id": 101,
              "file_id": 3,
              "sort_order": 2,
              "file": {
                "id": 3,
                "hash": "c",
                "path": "http://example.com/three.png",
                "size": 1,
                "mime_type": "image/png"
              }
            }
          ]
        } as dynamic,
      );
    }
    if (path.startsWith('/posts/100/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[
            ...List.generate(
              30,
              (index) => {
                    "id": 10 + index,
                    "post_id": 100,
                    "content": "Padding top level reply $index",
                    "author_id": 2,
                    "author": {
                      "id": 2,
                      "nickname": "User2",
                      "avatar": "http://example.com/avatar.png",
                      "student_id": "2"
                    },
                    "created_at": "2026-01-01T00:00:00.000Z"
                  }),
            {
              "id": 1,
              "post_id": 100,
              "content": "First level reply",
              "author_id": 2,
              "author": {
                "id": 2,
                "nickname": "User2",
                "avatar": "http://example.com/avatar.png",
                "student_id": "2"
              },
              "created_at": "2026-01-01T00:00:00.000Z"
            },
            {
              "id": 2,
              "post_id": 100,
              "parent_reply_id": 1,
              "content": "Second level reply",
              "author_id": 3,
              "author": {
                "id": 3,
                "nickname": "User3",
                "avatar": "http://example.com/avatar.png",
                "student_id": "3"
              },
              "created_at": "2026-01-01T00:00:00.000Z"
            },
            {
              "id": 3,
              "post_id": 100,
              "parent_reply_id": 1,
              "content": "Target second level reply",
              "author_id": 4,
              "author": {
                "id": 4,
                "nickname": "User4",
                "avatar": "http://example.com/avatar.png",
                "student_id": "4"
              },
              "created_at": "2026-01-01T00:00:00.000Z"
            }
          ],
          'total': 33,
          'next_cursor': '',
        } as dynamic,
      );
    } else if (path.startsWith('/posts/100')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          "id": 100,
          "title": "Post",
          "content": "Content",
          "author_id": 1,
          "created_at": "2026-01-01T00:00:00.000Z"
        } as dynamic,
      );
    }
    // 帖子 106：根评论带 51 条子回复的懒加载死锁回归 fixture。
    if (path.startsWith('/posts/106/replies/') && path.endsWith('/children')) {
      childrenRequestCount++;
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[
            {
              "id": 751,
              "post_id": 106,
              "parent_reply_id": 7,
              "content": "lazy-child-51",
              "author_id": 2,
              "author": {
                "id": 2,
                "nickname": "User2",
                "avatar": "http://example.com/avatar.png",
                "student_id": "2"
              },
              "created_at": "2026-01-01T00:00:00.000Z"
            }
          ],
          'next_cursor': '',
        } as dynamic,
      );
    }
    if (path.startsWith('/posts/106/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[
            {
              "id": 7,
              "post_id": 106,
              "content": "big thread root",
              "author_id": 2,
              "author": {
                "id": 2,
                "nickname": "User2",
                "avatar": "http://example.com/avatar.png",
                "student_id": "2"
              },
              "child_reply_count": 51,
              "created_at": "2026-01-01T00:00:00.000Z"
            },
            ...List.generate(50, (i) => {
                  "id": 701 + i,
                  "post_id": 106,
                  "parent_reply_id": 7,
                  "content": "child-${i + 1}",
                  "author_id": 2,
                  "author": {
                    "id": 2,
                    "nickname": "User2",
                    "avatar": "http://example.com/avatar.png",
                    "student_id": "2"
                  },
                  "created_at": "2026-01-01T00:00:00.000Z"
                }),
          ],
          'total': 52,
          'next_cursor': '',
        } as dynamic,
      );
    }
    if (path.startsWith('/posts/106')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          "id": 106,
          "title": "懒加载测试帖",
          "content": "Content",
          "board_id": 1,
          "author_id": 1,
          "post_type": "",
          "created_at": "2026-01-01T00:00:00.000Z",
          "images": <dynamic>[],
        } as dynamic,
      );
    }
    throw DioException(requestOptions: RequestOptions(path: path));
  }
}

class FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  final FakeDio _dio = FakeDio();

  @override
  bool get isLoggedIn => true;

  @override
  User? get user => User(
        id: 1,
        studentId: '123',
        nickname: 'Test',
        avatar: '',
        createdAt: DateTime.now(),
      );

  @override
  Dio get dio => _dio;
}

class FakePostProvider extends Fake
    with ChangeNotifier
    implements PostProvider {
  @override
  Post? postFor(int postId) => null;

  @override
  void updatePostInCache(Post post) {}
}

class FakeThemeProvider extends Fake
    with ChangeNotifier
    implements ThemeProvider {
  @override
  bool get isDarkMode => false;
}

Widget _postDetailTestApp(
  Post post, {
  bool isMarket = false,
  bool isDesktopSplitMode = false,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => FakeAuthProvider()),
      ChangeNotifierProvider<PostProvider>(create: (_) => FakePostProvider()),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => FakeThemeProvider()),
    ],
    child: MaterialApp(
      home: PostDetailScreen(
        postId: post.id,
        initialPost: post,
        isMarket: isMarket,
        isDesktopSplitMode: isDesktopSplitMode,
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    HttpOverrides.global = _MockHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

  testWidgets('PostDetailScreen 滚动到目标子回复并高亮测试', (WidgetTester tester) async {
    final mockUser = User(
      id: 1,
      studentId: '123',
      nickname: 'TestUser',
      avatar: 'http://example.com/avatar.png',
      createdAt: DateTime.now(),
    );

    final fakePost = Post(
      id: 100,
      title: '测试帖子',
      content: '这是内容',
      boardId: 1,
      authorId: 1,
      author: mockUser,
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
              create: (_) => FakeAuthProvider()),
          ChangeNotifierProvider<PostProvider>(
              create: (_) => FakePostProvider()),
          ChangeNotifierProvider<ThemeProvider>(
              create: (_) => FakeThemeProvider()),
        ],
        child: MaterialApp(
          home: PostDetailScreen(
            postId: 100,
            initialPost: fakePost,
            targetReplyId: 3, // 定位到二级回复 ID=3
          ),
        ),
      ),
    );

    // 初始渲染
    await tester.pump();

    // 在获取滚动区域偏移之前找到 Scrollable
    final scrollableFinder = find.byType(Scrollable).first;
    final ScrollableState scrollable = tester.state(scrollableFinder);
    final double initialOffset = scrollable.position.pixels;

    // 等待接口返回以及动画等各种回调执行
    await tester.pumpAndSettle();

    // 检查是否包含目标回复的内容并被点击拦截（hitTestable 代表其已在视口内）
    final textFinder = find.textContaining(
      'Target second level reply',
      findRichText: true,
    );
    expect(textFinder.hitTestable(), findsOneWidget);

    // 断言滚动条确实发生了向下的滚动
    expect(scrollable.position.pixels, greaterThan(initialOffset));

    // 验证高亮效果：查找包裹该文本的 AnimatedContainer
    final containerFinder = find
        .ancestor(
          of: textFinder,
          matching: find.byType(AnimatedContainer),
        )
        .first;

    expect(containerFinder, findsOneWidget);

    final AnimatedContainer container = tester.widget(containerFinder);
    final BoxDecoration decoration = container.decoration as BoxDecoration;

    // 断言初始处于高亮状态 (因为我们传了 targetReplyId=3，刚渲染完应该高亮)
    expect(decoration.color, isNot(Colors.transparent));

    // 快进 3 秒，等高亮定时器结束
    await tester.pump(const Duration(seconds: 3));
    // 等待 300 毫秒高亮褪色动画结束
    await tester.pumpAndSettle();

    final AnimatedContainer clearedContainer = tester.widget(find
        .ancestor(
          of: textFinder,
          matching: find.byType(AnimatedContainer),
        )
        .first);

    final BoxDecoration clearedDecoration =
        clearedContainer.decoration as BoxDecoration;

    // 断言高亮状态已消失
    expect(clearedDecoration.color, Colors.transparent);
  });

  testWidgets('PostDetailScreen renders three images with shared media view',
      (WidgetTester tester) async {
    final fakePost = _postWithImages(
      id: 101,
      title: 'Three images',
      imageUrls: [
        'http://example.com/one.png',
        'http://example.com/two.png',
        'http://example.com/three.png',
      ],
    );

    await tester.pumpWidget(_postDetailTestApp(fakePost));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Three images'), findsOneWidget);
    expect(find.byType(PostMediaView), findsOneWidget);
    expect(find.byType(AspectRatio), findsOneWidget);
  });

  testWidgets('PostDetailScreen renders one image with single-image treatment',
      (WidgetTester tester) async {
    final fakePost = _postWithImages(
      id: 102,
      title: 'Single image',
      imageUrls: ['http://example.com/one.png'],
    );

    await tester.pumpWidget(_postDetailTestApp(fakePost));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Single image'), findsOneWidget);
    expect(find.byType(PostMediaView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('PostDetailScreen renders two images side by side',
      (WidgetTester tester) async {
    final fakePost = _postWithImages(
      id: 103,
      title: 'Two images',
      imageUrls: [
        'http://example.com/one.png',
        'http://example.com/two.png',
      ],
    );

    await tester.pumpWidget(_postDetailTestApp(fakePost));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Two images'), findsOneWidget);
    expect(find.byType(PostMediaView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AspectRatio && widget.aspectRatio == 2,
      ),
      findsOneWidget,
    );
  });

  testWidgets('集市详情隐藏真实账号并按类型复制', (tester) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final post = Post.fromJson({
      'id': 104,
      'title': '集市商品',
      'content': '商品描述',
      'board_id': 2,
      'author_id': 2,
      'contact_type': 'wechat',
      'contact': 'secret_wx_123',
      'created_at': '2026-07-18T00:00:00.000Z',
    });
    await tester.pumpWidget(_postDetailTestApp(post, isMarket: true));
    await tester.pumpAndSettle();

    expect(find.text('secret_wx_123'), findsNothing);
    expect(find.text('微信 · 复制'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('market-contact-copy')),
    );
    await tester.tap(find.byKey(const ValueKey('market-contact-copy')));
    await tester.pumpAndSettle();

    expect(copiedText, 'secret_wx_123');
    expect(find.text('微信号已复制'), findsOneWidget);
  });

  testWidgets('无联系方式时只显示卖家信息', (tester) async {
    final post = Post.fromJson({
      'id': 105,
      'title': '集市商品',
      'content': '商品描述',
      'board_id': 2,
      'author_id': 2,
      'created_at': '2026-07-18T00:00:00.000Z',
    });
    await tester.pumpWidget(_postDetailTestApp(post, isMarket: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('market-seller-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('market-contact-copy')), findsNothing);
  });

  testWidgets('窄屏集市卖家行不溢出', (tester) async {
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = Post.fromJson({
      'id': 104,
      'title': '集市商品',
      'content': '商品描述',
      'board_id': 2,
      'author_id': 2,
      'contact_type': 'wechat',
      'contact': 'secret_wx_123',
      'created_at': '2026-07-18T00:00:00.000Z',
    });
    await tester.pumpWidget(_postDetailTestApp(post, isMarket: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('market-seller-row')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面分栏只渲染一条集市卖家信息', (tester) async {
    final post = Post.fromJson({
      'id': 104,
      'title': '集市商品',
      'content': '商品描述',
      'board_id': 2,
      'author_id': 2,
      'contact_type': 'wechat',
      'contact': 'secret_wx_123',
      'created_at': '2026-07-18T00:00:00.000Z',
    });
    await tester.pumpWidget(
      _postDetailTestApp(
        post,
        isMarket: true,
        isDesktopSplitMode: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('market-seller-row')), findsOneWidget);
    expect(find.text('secret_wx_123'), findsNothing);
  });

  testWidgets('帖子评论栏可直接插入表情并根据内容启用发送按钮', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = _postWithImages(
      id: 102,
      title: 'Emoji reply',
      imageUrls: ['http://example.com/one.png'],
    );
    await tester.pumpWidget(_postDetailTestApp(post));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写下你的想法...').last);
    await tester.pumpAndSettle();

    final sendButton = find.byKey(const ValueKey('post-reply-send-button'));
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('emoji-tab-face')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    await tester.pump();

    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('post-reply-input')),
    );
    expect(input.controller?.text, '😀');
    final enabledSendButton = tester.widget<IconButton>(sendButton);
    expect(enabledSendButton.onPressed, isNotNull);
    expect(
      enabledSendButton.style?.backgroundColor?.resolve({}),
      const Color(0xFF6B8EFF),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('帖子评论输入文字与表情按钮垂直居中对齐', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = _postWithImages(
      id: 104,
      title: 'Centered reply input',
      imageUrls: ['http://example.com/one.png'],
    );
    await tester.pumpWidget(_postDetailTestApp(post));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写下你的想法...').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('post-reply-input')),
      '0000',
    );
    await tester.pump();

    final editableFinder = find.descendant(
      of: find.byKey(const ValueKey('post-reply-input')),
      matching: find.byType(EditableText),
    );
    RenderEditable? editable;
    late void Function(RenderObject) findEditable;
    findEditable = (renderObject) {
      if (renderObject is RenderEditable) {
        editable = renderObject;
        return;
      }
      renderObject.visitChildren((child) {
        if (editable == null) findEditable(child);
      });
    };
    findEditable(tester.renderObject(editableFinder));
    expect(editable, isNotNull);
    final renderEditable = editable!;
    final caretRect = renderEditable.getLocalRectForCaret(
      const TextPosition(offset: 2),
    );
    final textCenterY = renderEditable.localToGlobal(caretRect.center).dy;
    final emojiCenterY = tester
        .getCenter(find.byKey(const ValueKey('post-reply-emoji-button')))
        .dy;

    expect((textCenterY - emojiCenterY).abs(), lessThanOrEqualTo(1));
  });

  testWidgets('帖子评论栏选择表情包后进入编辑器预览', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = _postWithImages(
      id: 103,
      title: 'Sticker reply',
      imageUrls: ['http://example.com/one.png'],
    );
    await tester.pumpWidget(_postDetailTestApp(post));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写下你的想法...').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('sticker-pack-tab-${appStickerGroups.first.id}'),
      ),
    );
    await tester.pumpAndSettle();

    final sticker = appStickerGroups.first.items.first;
    await tester.tap(find.byKey(ValueKey('sticker-${sticker.id}')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sticker-composer-preview')),
      findsOneWidget,
    );
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('post-reply-send-button')),
    );
    expect(sendButton.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('帖子评论栏选择收藏图片后进入编辑器预览', (tester) async {
    const imageUrl = '/uploads/reply-favorite.png';
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'image', 'image_url': imageUrl},
      ]),
    });
    EmojiFavoriteService.resetSharedInstanceForTesting();
    addTearDown(EmojiFavoriteService.resetSharedInstanceForTesting);
    expect(
      (await EmojiFavoriteService.instance.load()).single.imageUrl,
      imageUrl,
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = _postWithImages(
      id: 105,
      title: 'Favorite image reply',
      imageUrls: ['http://example.com/one.png'],
    );
    await tester.pumpWidget(_postDetailTestApp(post));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写下你的想法...').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey('favorite-image:/uploads/reply-favorite.png'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('favorite-image-composer-preview')),
      findsOneWidget,
    );
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('post-reply-send-button')),
    );
    expect(sendButton.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('楼中楼超过50条子回复时首次懒加载不被自身loading锁挡住', (tester) async {
    FakeDio.childrenRequestCount = 0;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final post = Post(
      id: 106,
      title: '懒加载测试帖',
      content: 'Content',
      boardId: 1,
      authorId: 1,
      author: User(
        id: 1,
        studentId: '123',
        nickname: 'TestUser',
        avatar: '',
        createdAt: DateTime.now(),
      ),
      createdAt: DateTime.now(),
    );
    await tester.pumpWidget(_postDetailTestApp(post));
    await tester.pumpAndSettle();

    // 根评论只带了 50 条子回复，但真实总数 51 → 出现"共 51 条回复"入口。
    expect(find.textContaining('共 51 条回复'), findsOneWidget);

    await tester.tap(find.textContaining('共 51 条回复'));
    await tester.pumpAndSettle();

    // 死锁修复：children 请求必须真正发出。
    // 修复前 loadMoreChildren 首句 `if (sheetChildrenLoading) return` 被初始化的
    // loading=true 挡住，请求永远不发、spinner 永远转。
    expect(FakeDio.childrenRequestCount, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('相关回复共 51 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
