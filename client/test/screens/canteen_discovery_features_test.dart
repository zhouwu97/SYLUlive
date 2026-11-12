import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/admin_canteen_operations_screen.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';
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
  group('下架只读与排行范围', offlineAndScopeTests);

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
    await tester.tap(find.text('出餐快').last);
    await tester.pumpAndSettle();

    expect(find.text('出餐快的店'), findsOneWidget);
    expect(find.text('排队久的店'), findsNothing);
    expect(find.text('出餐快'), findsOneWidget, reason: '筛选胶囊显示当前标签');
  });
}

void offlineAndScopeTests() {
  testWidgets('排行默认看现有商家，切到全部排名会带上已下架商家并标注', (tester) async {
    final scopes = <String?>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.path == '/canteens/rankings') {
        final scope = options.queryParameters['scope']?.toString();
        scopes.add(scope);
        if (scope == 'all') {
          return _json('{"items":['
              '{"rank":1,"id":9,"name":"老字号面馆","rating_count":20,"average_star":4.9,"ranking_score":90,"is_offline":true,"operating_status":"offline"},'
              '{"rank":2,"id":1,"name":"营业中的店","rating_count":5,"average_star":4.5,"ranking_score":80}'
              '],"meta":{"total":2}}');
        }
        return _json('{"items":['
            '{"rank":1,"id":1,"name":"营业中的店","rating_count":5,"average_star":4.5,"ranking_score":80}'
            '],"meta":{"total":1}}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(_app(dio, const CanteenRankingScreen()));
    await tester.pumpAndSettle();

    expect(scopes, [null], reason: '默认现有商家排名，不带 scope');
    expect(find.text('老字号面馆'), findsNothing);
    expect(find.text('只排营业中的商家，综合分兼顾评分与评价人数'), findsOneWidget);

    await tester.tap(find.text('全部排名'));
    await tester.pumpAndSettle();
    expect(scopes.last, 'all');
    expect(find.text('老字号面馆'), findsOneWidget);
    expect(find.text('已下架'), findsOneWidget);

    await tester.tap(find.text('现有商家'));
    await tester.pumpAndSettle();
    expect(find.text('老字号面馆'), findsNothing);
  });

  testWidgets('下架商家详情：显示只读说明，作者不能改删，投票会提示只读', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final requests = <String>[];
    dio.httpClientAdapter = _Adapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens/1/detail') {
        return _json(
            '{"canteen":{"id":1,"name":"关门的店","image":"","verified":true,'
            '"operating_status":"offline","is_offline":true},'
            '"rating_count":2,"reviewer_count":2,"average_star":4.0,'
            '"review_action":{"can_create":true,"can_edit_latest":true,"latest_review_id":11},'
            '"my_latest_review":{"review_event_id":11},'
            '"display_reviews":['
            '{"id":11,"source":"v2","review_source":"v2","user_id":7,"user_name":"我","comment":"我的评价","overall_score":4,"star":4,"score_version":2,"created_at":"2026-11-01T08:00:00Z"},'
            '{"id":12,"source":"v2","review_source":"v2","user_id":8,"user_name":"别人","comment":"别人的评价","overall_score":4,"star":4,"score_version":2,"created_at":"2026-11-02T08:00:00Z"}'
            ']}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider<AuthProvider>.value(value: _LoggedInAuth()),
      ],
      child: const MaterialApp(
        home: CanteenDetailScreen(canteenId: 1, canteenName: '关门的店'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('商家已下架 · 内容只读'), findsOneWidget);
    expect(find.text('商家已下架，内容仅供查看'), findsOneWidget);

    await tester.ensureVisible(find.text('我的评价'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('评价操作'), findsNothing, reason: '下架后作者没有修改/删除入口');

    await tester.ensureVisible(find.text('别人的评价'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined).last);
    await tester.pump();
    expect(find.text('该商家已下架，评价和图片仅供查看；如需修改或删除请联系管理员'), findsOneWidget);
    expect(requests.where((r) => r.startsWith('PUT')), isEmpty);
  });

  testWidgets('食堂运营按状态筛选，下架商家显示时间和原因，下架前说明影响', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((options) async {
      if (options.path == '/canteens/admin-list') {
        return _json('{"items":['
            '{"id":1,"name":"营业中的店","image":"","verified":true,"created_by":1,"rating_count":5,"average_star":4.5,"dish_count":6,"location_area":"一食堂","location_floor":"一楼"},'
            '{"id":2,"name":"关门的店","image":"","verified":true,"created_by":1,"rating_count":2,"average_star":4.0,"dish_count":3,'
            '"operating_status":"offline","is_offline":true,"offlined_at":"2026-11-10T08:00:00Z","offline_reason":"档口转让"}'
            '],"active_count":1,"offline_count":1}');
      }
      return _json('{"error":"not found"}', 404);
    });
    await tester.pumpWidget(_app(dio, const AdminCanteenOperationsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('全部 2'), findsOneWidget);
    expect(find.text('营业中 1'), findsOneWidget);
    expect(find.text('已下架 1'), findsOneWidget);
    expect(find.textContaining('原因：档口转让'), findsOneWidget);
    expect(find.text('恢复营业'), findsOneWidget);

    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();
    expect(find.text('营业中的店'), findsNothing);
    expect(find.text('关门的店'), findsOneWidget);

    await tester.tap(find.text('全部 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下架商家'));
    await tester.pumpAndSettle();
    expect(find.text('下架「营业中的店」'), findsOneWidget);
    expect(find.textContaining('不再参与现有商家排名'), findsOneWidget);
    expect(find.textContaining('只有管理员可以处理'), findsOneWidget);
  });
}
