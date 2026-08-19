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

/// 可控 FakeDio：按场景返回回复列表 / 点赞结果 / 失败。
class LikeScenarioDio extends Fake implements Dio {
  LikeScenarioDio({
    this.likeShouldFail = false,
    this.likeConflict = false,
    this.likeDelay = Duration.zero,
    this.replies = const [],
  });

  final bool likeShouldFail;
  final bool likeConflict;
  final Duration likeDelay;
  final List<Map<String, dynamic>> replies;

  int likeRequests = 0;
  int unlikeRequests = 0;
  String? lastPath;
  Map<String, dynamic>? lastQuery;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    lastPath = path;
    lastQuery = queryParameters;
    if (path.startsWith('/posts/200/replies')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': replies,
          'total': replies.length,
          'next_cursor': '',
        } as dynamic,
      );
    }
    if (path.endsWith('/featured-application-status')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {'has_pending': false} as dynamic,
      );
    }
    if (path.startsWith('/posts/200')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'id': 200,
          'title': '测试帖子',
          'content': '内容',
          'board_id': 1,
          'author_id': 1,
          'created_at': '2026-08-01T00:00:00.000Z',
          'images': <dynamic>[],
          'reply_count': replies.length,
        } as dynamic,
      );
    }
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      data: {} as dynamic,
    );
  }

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onSendProgress,
    void Function(int, int)? onReceiveProgress,
  }) async {
    lastPath = path;
    likeRequests++;
    await Future<void>.delayed(likeDelay);
    if (likeShouldFail) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        error: 'network down',
      );
    }
    if (likeConflict) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        response: Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 409,
          data: {'error': '该回复当前不允许点赞'},
        ),
        type: DioExceptionType.badResponse,
      );
    }
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: {'message': '已点赞'} as dynamic,
    );
  }

  @override
  Future<Response<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onSendProgress,
    void Function(int, int)? onReceiveProgress,
  }) async {
    lastPath = path;
    unlikeRequests++;
    await Future<void>.delayed(likeDelay);
    if (likeShouldFail) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        error: 'network down',
      );
    }
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: {'message': '已取消点赞'} as dynamic,
    );
  }
}

class LikeTestAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  LikeTestAuthProvider(this._dio);
  final LikeScenarioDio _dio;

  @override
  bool get isLoggedIn => true;

  @override
  String? get token => 'test-token';

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

class LikeTestPostProvider extends Fake with ChangeNotifier
    implements PostProvider {
  LikeTestPostProvider(this._dio);
  final LikeScenarioDio _dio;

  @override
  Post? postFor(int postId) => null;

  @override
  void updatePostInCache(Post post) {}

  @override
  Future<ReplyLikeRequestResult> likeReply(int replyId) =>
      _dioLike(replyId, like: true);

  @override
  Future<ReplyLikeRequestResult> unlikeReply(int replyId) =>
      _dioLike(replyId, like: false);

  Future<ReplyLikeRequestResult> _dioLike(int replyId,
      {required bool like}) async {
    try {
      if (like) {
        await _dio.post('/replies/$replyId/like');
      } else {
        await _dio.delete('/replies/$replyId/like');
      }
      return const ReplyLikeRequestResult(success: true, conflict: false);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      return ReplyLikeRequestResult(
        success: false,
        conflict: statusCode != null && statusCode >= 400 && statusCode < 500,
        errorMessage: '点赞失败',
      );
    }
  }
}

class LikeTestThemeProvider extends Fake
    with ChangeNotifier
    implements ThemeProvider {
  @override
  bool get isDarkMode => false;
}

Map<String, dynamic> replyJson(int id, {int likeCount = 12, bool isLiked = false}) {
  return {
    'id': id,
    'post_id': 200,
    'parent_reply_id': id == 2 ? 1 : null,
    'author_id': 2,
    'content': '评论内容 $id',
    'status': 'normal',
    'like_count': likeCount,
    'is_liked': isLiked,
    'images': <dynamic>[],
    'author': {
      'id': 2,
      'student_id': 'S2',
      'nickname': '小张',
      'avatar': '',
      'created_at': '2026-01-01T00:00:00.000Z',
    },
    'created_at': '2026-08-01T00:00:00.000Z',
  };
}

Widget buildApp(LikeScenarioDio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => LikeTestAuthProvider(dio),
      ),
      ChangeNotifierProvider<PostProvider>(
        create: (_) => LikeTestPostProvider(dio),
      ),
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => LikeTestThemeProvider(),
      ),
    ],
    child: const MaterialApp(
      home: PostDetailScreen(postId: 200),
    ),
  );
}

Future<LikeScenarioDio> pumpDetailWithReply(WidgetTester tester,
    {LikeScenarioDio? dio}) async {
  final d = dio ??
      LikeScenarioDio(replies: [
        replyJson(1, likeCount: 12, isLiked: false),
      ]);
  await tester.pumpWidget(buildApp(d));
  await tester.pumpAndSettle();
  return d;
}

void main() {
  testWidgets('成功：♡12 → 点击 → 立即 ♥13 → 2xx → 保持 ♥13', (tester) async {
    final dio = await pumpDetailWithReply(tester);

    // 初始：未点赞，显示 favorite_border
    expect(find.byIcon(Icons.favorite_border), findsWidgets);
    expect(find.text('12'), findsWidgets);

    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();

    // 乐观更新：立即变成 favorite
    expect(find.byIcon(Icons.favorite), findsWidgets);
    expect(find.text('13'), findsWidgets);

    // 请求完成
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsWidgets);
    expect(find.text('13'), findsWidgets);
    expect(dio.likeRequests, 1);
  });

  testWidgets('网络失败：♡12 → ♥13 → fail → 回滚 ♡12', (tester) async {
    await pumpDetailWithReply(
      tester,
      dio: LikeScenarioDio(
        replies: [replyJson(1, likeCount: 12, isLiked: false)],
        likeShouldFail: true,
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    expect(find.byIcon(Icons.favorite), findsWidgets);

    await tester.pumpAndSettle();
    // 回滚
    expect(find.byIcon(Icons.favorite_border), findsWidgets);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.text('12'), findsWidgets);
  });

  testWidgets('取消点赞失败：♥13 → ♡12 → fail → 回滚 ♥13', (tester) async {
    final dio = await pumpDetailWithReply(
      tester,
      dio: LikeScenarioDio(
        replies: [replyJson(1, likeCount: 13, isLiked: true)],
        likeShouldFail: true,
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite).first);
    await tester.pump();
    expect(find.byIcon(Icons.favorite_border), findsWidgets);
    expect(find.text('12'), findsWidgets);

    await tester.pumpAndSettle();
    // 回滚到已点赞
    expect(find.byIcon(Icons.favorite), findsWidgets);
    expect(find.text('13'), findsWidgets);
    expect(dio.unlikeRequests, 1);
  });

  testWidgets('pending：请求未结束前二次点击不发第二个请求', (tester) async {
    final dio = await pumpDetailWithReply(
      tester,
      dio: LikeScenarioDio(
        replies: [replyJson(1, likeCount: 12, isLiked: false)],
        likeDelay: const Duration(milliseconds: 200),
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump(const Duration(milliseconds: 50));

    // 在途期间再点一次：应被 pending 拦截
    await tester.tap(find.byIcon(Icons.favorite).first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(dio.likeRequests, 1, reason: '防连点：只能发一个请求');
  });

  testWidgets('409 冲突：回滚并重新拉取回复列表', (tester) async {
    await pumpDetailWithReply(
      tester,
      dio: LikeScenarioDio(
        replies: [replyJson(1, likeCount: 12, isLiked: false)],
        likeConflict: true,
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();

    // 回滚到服务端一致的旧状态
    expect(find.byIcon(Icons.favorite_border), findsWidgets);
    expect(find.text('12'), findsWidgets);
  });
}
