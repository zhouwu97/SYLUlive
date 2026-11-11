import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_ranking_screen.dart';
import 'package:shenliyuan/screens/canteen_screen.dart';
import 'package:shenliyuan/widgets/canteen/canteen_hero_recommendation.dart';

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

String _hero(int id, String name) =>
    '{"canteen_id":$id,"canteen_name":"$name","image":"","average_star":4.5,'
    '"rating_count":6,"ranking_score":80,"title":"综合推荐","reason":"同学们常常提到“味道不错”"}';

Widget _app(Dio dio, Widget home, {AuthProvider? auth}) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(dio)),
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => auth ?? AuthProvider(dio)),
      ],
      child: MaterialApp(home: home),
    );

void main() {
  testWidgets('今天吃什么可以换一家，候选只有一家时不显示按钮', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.path == '/canteens/home') {
        return _json('{"hero":${_hero(1, '甲店')},'
            '"hero_candidates":[${_hero(1, '甲店')},${_hero(2, '乙店')},${_hero(3, '丙店')}],'
            '"ranking_entry":{"top":{},"total":3},"hot_dishes":[],"recent_reviews":[],"feed":[]}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(_app(dio, const CanteenScreen()));
    await tester.pumpAndSettle();

    String heroName() {
      final card = tester.widget<CanteenHeroRecommendationCard>(
          find.byType(CanteenHeroRecommendationCard));
      return card.hero.canteenName;
    }

    final first = heroName();
    expect(['甲店', '乙店', '丙店'], contains(first));
    await tester.tap(find.text('换一家'));
    await tester.pumpAndSettle();
    final second = heroName();
    expect(second, isNot(first));
    await tester.tap(find.text('换一家'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('换一家'));
    await tester.pumpAndSettle();
    expect(heroName(), first, reason: '三家候选轮换一圈回到起点');
  });

  testWidgets('登录后首页显示“我常去”，未登录时不显示', (tester) async {
    Dio dioWithFavorites(List<String> requests) {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = _Adapter((options) async {
        requests.add(options.path);
        if (options.path == '/canteens/home') {
          return _json('{"hero":null,"ranking_entry":{"top":{},"total":0},'
              '"hot_dishes":[],"recent_reviews":[],"feed":[]}');
        }
        if (options.path == '/user/canteen-favorites') {
          return _json(
              '{"items":[{"id":5,"name":"常去的面馆","image":"","verified":true,'
              '"created_by":1,"rating_count":3,"average_star":4.4,"location_area":"一食堂","location_floor":"一楼"}]}');
        }
        return _json('{"error":"not found"}', 404);
      });
      return dio;
    }

    final loggedInRequests = <String>[];
    await tester.pumpWidget(_app(
        dioWithFavorites(loggedInRequests), const CanteenScreen(),
        auth: _LoggedInAuth()));
    await tester.pumpAndSettle();
    expect(find.text('我常去'), findsOneWidget);
    expect(find.text('常去的面馆'), findsOneWidget);
    expect(find.text('一食堂·一楼 · 4.4 分'), findsOneWidget);

    // 换一棵新树，确保第二段用的是全新的 Provider，而不是沿用上一段的登录态。
    await tester.pumpWidget(const SizedBox());
    final anonymousRequests = <String>[];
    await tester.pumpWidget(
        _app(dioWithFavorites(anonymousRequests), const CanteenScreen()));
    await tester.pumpAndSettle();
    expect(find.text('我常去'), findsNothing);
    expect(anonymousRequests, isNot(contains('/user/canteen-favorites')));
  });

  testWidgets('排行按评价标签筛选，只留近期被这样评价的商家', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.path == '/canteens/rankings') {
        return _json('{"items":['
            '{"rank":1,"id":1,"name":"出餐快的店","rating_count":5,"average_star":4.5,"ranking_score":80,'
            '"summary_tags":[{"key":"taste_good","name":"味道不错","count":3}],"tag_keys":["taste_good","serving_fast"]},'
            '{"rank":2,"id":2,"name":"排队久的店","rating_count":5,"average_star":4.0,"ranking_score":75,'
            '"summary_tags":[],"tag_keys":["queue_long"]}'
            '],"meta":{"total":2}}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(_app(dio, const CanteenRankingScreen()));
    await tester.pumpAndSettle();
    expect(find.text('出餐快的店'), findsOneWidget);
    expect(find.text('排队久的店'), findsOneWidget);

    await tester.ensureVisible(find.text('标签'));
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '出餐快'));
    await tester.pumpAndSettle();

    expect(find.text('出餐快的店'), findsOneWidget);
    expect(find.text('排队久的店'), findsNothing);
    expect(find.text('出餐快'), findsOneWidget, reason: '筛选胶囊显示当前标签');
  });
}
