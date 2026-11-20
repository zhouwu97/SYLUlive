import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;
  _Adapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, [int status = 200]) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

String _review(int id, String comment) =>
    '{"id":$id,"review_id":$id,"source":"v2","review_source":"v2","user_id":${id + 100},'
    '"user_name":"同学$id","comment":"$comment","overall_score":4,"star":4,'
    '"helpful_count":0,"unhelpful_count":0,"score_version":2,"created_at":"2026-11-0${id}T08:00:00Z"}';

void main() {
  group('收藏', favoriteTests);

  testWidgets('详情页首屏只带第一页评价，加载更多与切换排序只请求评价接口', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      final query = options.uri.query;
      requests.add('${options.path}?$query');
      if (options.path == '/canteens/1/detail') {
        expect(options.queryParameters['compact'], '1');
        return _json(
            '{"canteen":{"id":1,"name":"我家有面","image":"","verified":true},'
            '"rating_count":3,"reviewer_count":3,"average_star":4.0,'
            '"display_reviews":[${_review(1, '首屏第一条')}],'
            '"display_reviews_total":3,"display_reviews_has_more":true}');
      }
      if (options.path == '/canteens/1/display-reviews') {
        final offset = options.queryParameters['offset'];
        final sort = options.queryParameters['sort'];
        if (sort == 'latest') {
          return _json(
              '{"items":[${_review(3, '最新排序第一条')}],"total":3,"has_more":false}');
        }
        expect(offset, 1);
        return _json(
            '{"items":[${_review(2, '第二页内容')}],"total":3,"has_more":false}');
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
      ],
      child: const MaterialApp(
        home: CanteenDetailScreen(canteenId: 1, canteenName: '我家有面'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('加载更多评价'));
    await tester.pumpAndSettle();
    expect(find.text('首屏第一条'), findsOneWidget);
    final detailCalls =
        requests.where((r) => r.startsWith('/canteens/1/detail')).length;

    await tester.tap(find.text('加载更多评价'));
    await tester.pumpAndSettle();
    expect(find.text('首屏第一条'), findsOneWidget);
    expect(find.text('第二页内容'), findsOneWidget);
    expect(find.text('加载更多评价'), findsNothing);

    await tester.ensureVisible(find.text('最新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('最新排序第一条'));
    expect(find.text('最新排序第一条'), findsOneWidget);
    expect(find.text('第二页内容'), findsNothing);

    // 翻页和切换排序都没有重新拉整页详情。
    expect(requests.where((r) => r.startsWith('/canteens/1/detail')).length,
        detailCalls);
  });
}

class _LoggedInAuth extends Fake with ChangeNotifier implements AuthProvider {
  @override
  bool get isLoggedIn => true;

  @override
  User? get user => User(
        id: 7,
        studentId: '20260007',
        nickname: '同学',
        avatar: '',
        createdAt: DateTime(2026, 1, 1),
        studentVerified: true,
        eduBound: true,
      );
}

void favoriteTests() {
  testWidgets('详情页收藏：点一下发 PUT 并切换图标，失败时回滚', (tester) async {
    final requests = <String>[];
    var failNext = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.path == '/canteens/1/detail') {
        return _json(
            '{"canteen":{"id":1,"name":"我家有面","image":"","verified":true},'
            '"rating_count":0,"average_star":0,"is_favorite":false,"display_reviews":[]}');
      }
      if (options.path == '/user/canteen-favorites/1') {
        requests.add(options.method);
        return failNext
            ? _json('{"error":"收藏失败"}', 500)
            : _json('{"favorited":${options.method == 'PUT'}}');
      }
      if (options.path == '/user/canteen-favorites') {
        return _json('{"items":[]}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider<AuthProvider>.value(value: _LoggedInAuth()),
      ],
      child: const MaterialApp(
        home: CanteenDetailScreen(canteenId: 1, canteenName: '我家有面'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byTooltip('收藏商家'), findsOneWidget);
    expect(find.byTooltip('分享商家'), findsOneWidget);
    await tester.tap(find.byTooltip('收藏商家'));
    await tester.pumpAndSettle();
    expect(requests, ['PUT']);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    failNext = true;
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(requests, ['PUT', 'DELETE']);
    expect(find.byTooltip('取消收藏'), findsOneWidget, reason: '失败后回滚为已收藏');
  });
}
