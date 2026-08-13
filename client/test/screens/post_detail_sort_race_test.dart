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

/// 可控回复排序 Dio：hot 慢 / latest 快，用于验证 requestVersion。
class SortRaceDio extends Fake implements Dio {
  SortRaceDio({
    this.hotDelay = Duration.zero,
    this.latestDelay = Duration.zero,
  });

  final Duration hotDelay;
  final Duration latestDelay;

  final List<String> requestedSorts = [];
  int hotRequests = 0;
  int latestRequests = 0;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    if (path.startsWith('/posts/300/replies')) {
      final sort = queryParameters?['sort'] as String? ?? 'hot';
      requestedSorts.add(sort);
      final delay = sort == 'latest' ? latestDelay : hotDelay;
      await Future<void>.delayed(delay);
      if (sort == 'latest') latestRequests++;
      if (sort == 'hot') hotRequests++;
      final data = <String, dynamic>{
        'replies': <Map<String, dynamic>>[
          _reply(1, sort == 'latest' ? '最新第一条' : '热门第一条'),
        ],
        'total': 1,
        'next_cursor': '',
      };
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: data as dynamic,
      );
    }
    if (path.endsWith('/featured-application-status')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {'has_pending': false} as dynamic,
      );
    }
    if (path.startsWith('/posts/300')) {
      return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'id': 300,
          'title': '排序测试帖',
          'content': '内容',
          'board_id': 1,
          'author_id': 1,
          'created_at': '2026-08-01T00:00:00.000Z',
          'images': <dynamic>[],
        } as dynamic,
      );
    }
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      data: {} as dynamic,
    );
  }

  Map<String, dynamic> _reply(int id, String content) => {
        'id': id,
        'post_id': 300,
        'author_id': 2,
        'content': content,
        'status': 'normal',
        'like_count': 0,
        'is_liked': false,
        'images': <dynamic>[],
        'created_at': '2026-08-01T00:00:00.000Z',
      };
}

class RaceAuthProvider extends Fake with ChangeNotifier implements AuthProvider {
  RaceAuthProvider(this._dio);
  final SortRaceDio _dio;

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

class RacePostProvider extends Fake with ChangeNotifier
    implements PostProvider {
  @override
  Post? postFor(int postId) => null;

  @override
  void updatePostInCache(Post post) {}
}

class RaceThemeProvider extends Fake
    with ChangeNotifier
    implements ThemeProvider {
  @override
  bool get isDarkMode => false;
}

Widget buildRaceApp(SortRaceDio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => RaceAuthProvider(dio),
      ),
      ChangeNotifierProvider<PostProvider>(
        create: (_) => RacePostProvider(),
      ),
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => RaceThemeProvider(),
      ),
    ],
    child: const MaterialApp(
      home: PostDetailScreen(postId: 300),
    ),
  );
}

void main() {
  testWidgets('Hot 慢 / Latest 快：最终显示最后一次选择的结果', (tester) async {
    final dio = SortRaceDio(
      hotDelay: const Duration(milliseconds: 300),
      latestDelay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(buildRaceApp(dio));
    await tester.pumpAndSettle();

    // 默认 hot（首次加载完成）
    expect(dio.requestedSorts.first, 'hot');
    expect(find.textContaining('热门第一条'), findsOneWidget);

    // 打开排序弹层并切到 Latest
    await tester.tap(find.byKey(const ValueKey('reply-sort-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新').last);
    await tester.pumpAndSettle();
    expect(dio.latestRequests, greaterThanOrEqualTo(1));
    expect(find.textContaining('最新第一条'), findsOneWidget);

    // 切到 Hot（慢请求），马上又切 Latest（快请求）
    await tester.tap(find.byKey(const ValueKey('reply-sort-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('热门').last);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const ValueKey('reply-sort-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新').last);
    await tester.pumpAndSettle();

    // 最终选择的是最新，必须显示最新内容（不能被慢的 hot 响应覆盖）
    expect(find.textContaining('最新第一条'), findsWidgets);
    expect(find.textContaining('热门第一条'), findsNothing);
  });

  testWidgets('切换排序只刷新回复，不重新请求帖子详情', (tester) async {
    final dio = SortRaceDio();
    await tester.pumpWidget(buildRaceApp(dio));
    await tester.pumpAndSettle();

    final repliesRequestsBefore = dio.requestedSorts.length;

    // 当前已是最新（默认 hot 后切一次），再切回 hot，只应多一次 replies 请求。
    await tester.tap(find.byKey(const ValueKey('reply-sort-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新').last);
    await tester.pumpAndSettle();
    expect(dio.requestedSorts.length, repliesRequestsBefore + 1);
  });
}
