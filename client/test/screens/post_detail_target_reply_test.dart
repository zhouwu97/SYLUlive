import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';

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
  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    if (path.startsWith('/posts/102/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: [] as dynamic,
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
        data: [] as dynamic,
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
        data: [] as dynamic,
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
        data: [
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
        ] as dynamic,
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
  void updatePostInCache(Post post) {}
}

class FakeThemeProvider extends Fake
    with ChangeNotifier
    implements ThemeProvider {
  @override
  bool get isDarkMode => false;
}

Widget _postDetailTestApp(Post post) {
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
    expect(
        find.text('Target second level reply').hitTestable(), findsOneWidget);

    // 断言滚动条确实发生了向下的滚动
    expect(scrollable.position.pixels, greaterThan(initialOffset));

    // 验证高亮效果：查找包裹该文本的 AnimatedContainer
    final textFinder = find.text('Target second level reply');
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

  testWidgets('PostDetailScreen renders post images as a three-column grid',
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
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! GridView) return false;
        final delegate = widget.gridDelegate;
        return delegate is SliverGridDelegateWithFixedCrossAxisCount &&
            delegate.crossAxisCount == 3 &&
            delegate.childAspectRatio == 1;
      }),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl.startsWith('http://example.com/') &&
            widget.imageUrl.endsWith('.png'),
      ),
      findsNWidgets(3),
    );
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
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl == 'http://example.com/one.png' &&
            widget.fit == BoxFit.contain,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl == 'http://example.com/one.png',
      ),
      findsOneWidget,
    );
    final singleImageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is CachedNetworkImage &&
          widget.imageUrl == 'http://example.com/one.png',
    );
    expect(
      find.ancestor(
        of: singleImageFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is SizedBox && widget.width == double.infinity,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: singleImageFinder,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Center &&
              widget.widthFactor == null &&
              widget.heightFactor == null,
        ),
      ),
      findsOneWidget,
    );
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
    expect(find.byType(GridView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AspectRatio && widget.aspectRatio == 1,
      ),
      findsNWidgets(2),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl.startsWith('http://example.com/') &&
            widget.imageUrl.endsWith('.png') &&
            widget.fit == BoxFit.cover,
      ),
      findsNWidgets(2),
    );
  });
}
