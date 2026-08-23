import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_screen.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_entry.dart';

const _homeBody =
    '{"hero":{"type":"recommended_store","canteen_id":1,"canteen_name":"一食堂二楼",'
    '"image":"/uploads/a.jpg","ranking_score":86.0,"average_star":4.6,"rating_count":5,'
    '"title":"今日推荐","reason":"同学们常常提到\\u201c味道不错\\u201d","tags":["味道不错"]},'
    '"ranking_entry":{"top":{"id":1,"name":"一食堂二楼","ranking_score":86.0},"total":3},'
    '"today_effective_reviewer_count":3,'
    '"recent_effective_review_count":37,'
    '"recent_reviews":['
    '{"source":"v2","review_id":99,"canteen_id":1,"canteen_name":"一食堂二楼",'
    '"user_id":12,"user_name":"z同学","credit_score":96,"overall_score":4.6,'
    '"dimension_scores":{"taste":4.8,"value":4.4,"queue":4.2},'
    '"comment":"麻辣拌今天味道稳定，午饭高峰排了大概8分钟。",'
    '"recommended_dishes":["麻辣拌"],"history_count":3,"created_at":"2026-08-20T03:32:00Z"}'
    '],'
    '"hot_dishes":['
    '{"id":11,"name":"麻辣拌","canteen_id":1,"canteen_name":"一食堂二楼",'
    '"average_score":4.8,"reviewer_count":21},'
    '{"id":12,"name":"杂粮煎饼","canteen_id":2,"canteen_name":"二食堂",'
    '"average_score":4.7,"reviewer_count":17}'
    '],'
    '"feed":['
    '{"id":"recent_photo:5","type":"recent_photo","canteen_id":2,"canteen_name":"二食堂",'
    '"dish_id":5,"dish_name":"红烧牛肉面","title":"同学最近实拍","images":["/uploads/p.jpg"]},'
    '{"id":"stable_choice:3","type":"stable_choice","canteen_id":3,"canteen_name":"三食堂面馆",'
    '"ranking_score":78.0,"average_star":4.3,"rating_count":3,"title":"想吃稳一点？",'
    '"reason":"评价样本相对更多，结果受单条评价影响更小","tags":["分量足","出餐快"]}'
    ']}';

const _canteensListBody = '['
    '{"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg","verified":true,"created_by":1,"rating_count":5,"average_star":4.6,"ranking_score":86.0},'
    '{"id":3,"name":"三食堂面馆","image":"","verified":true,"created_by":1,"rating_count":3,"average_star":4.3,"ranking_score":78.0},'
    '{"id":4,"name":"川渝小吃（未进推荐流）","image":"/uploads/c.jpg","verified":true,"created_by":1,"rating_count":2,"average_star":4.0,"ranking_score":70.0}'
    ']';

const _homeWithoutDishesBody = '{"hero":null,'
    '"ranking_entry":{"top":{},"total":0},'
    '"today_effective_reviewer_count":0,"recent_effective_review_count":0,'
    '"hot_dishes":[],"recent_reviews":[],"feed":['
    '{"id":"stable_choice:3","type":"stable_choice","canteen_id":3,"canteen_name":"旧 Feed 不应出现",'
    '"title":"想吃稳一点？"}]}';

/// 构造一个返回食堂首页与全量食堂数据的 Dio Adapter。
Dio _buildDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens/home' && options.method == 'GET') {
      return _json(_homeBody);
    }
    if (options.path == '/canteens' && options.method == 'GET') {
      return _json(_canteensListBody);
    }
    return ResponseBody.fromString('{"error":"not found"}', 404);
  });
  return dio;
}

ResponseBody _json(String body) => ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

class FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) _handler;
  FakeAdapter(this._handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Widget _buildApp({
  Dio? dio,
  ThemeData? theme,
  double textScale = 1.0,
}) {
  final d = dio ?? _buildDio();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(d)),
      ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(d)),
      ChangeNotifierProvider(create: (_) => AuthProvider(d)),
    ],
    child: MaterialApp(
      theme: theme,
      home: const CanteenScreen(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

void main() {
  testWidgets('进入页面请求 /canteens/home（发现聚合），不请求旧整榜', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens/home' && options.method == 'GET') {
        return _json(_homeBody);
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio: dio));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r == 'GET /canteens/home'), hasLength(1));
    // 旧整榜列表接口不应在未搜索时被首页使用。
    expect(requests.where((r) => r == 'GET /canteens'), isEmpty);
    expect(find.text('校园餐饮'), findsOneWidget);
    expect(find.byTooltip('添加商家'), findsOneWidget);
    expect(find.text('发布评价'), findsNothing);
    expect(find.text('店铺'), findsNothing);
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('首页按参考结构展示今天吃什么、快捷入口与热门菜品', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('今天吃什么'), findsOneWidget);
    expect(find.text('同学真实评价 · 商家菜品实拍'), findsOneWidget);
    expect(find.text('综合评价 4.6 · 五维数据待补充'), findsOneWidget);

    final scrollableFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          widget.axisDirection == AxisDirection.down &&
          widget.physics is AlwaysScrollableScrollPhysics,
    );
    expect(scrollableFinder, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('热门菜品'),
      400,
      scrollable: scrollableFinder,
    );

    expect(find.text('热门菜品'), findsOneWidget);
    expect(find.text('今日新增评价'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('一食堂二楼'), findsOneWidget);
    expect(find.text('商家排行'), findsOneWidget);
    // 首页不再以整榜数字排名渲染（不存在 01/02 榜单数字）。
    expect(find.text('01'), findsNothing);
  });

  testWidgets('快捷入口两张卡片底边对齐', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    final rankingRect = tester.getRect(find.byType(CanteenRankingEntryCard));
    final todayReviewRect = tester.getRect(
      find.byKey(const Key('canteen_today_review_card')),
    );
    final rankingTitleRect = tester.getRect(find.text('商家排行'));
    final todayReviewTitleRect = tester.getRect(find.text('今日新增评价'));

    expect(rankingRect.height, todayReviewRect.height);
    expect(rankingRect.bottom, todayReviewRect.bottom);
    expect(rankingTitleRect.top, todayReviewTitleRect.top);
  });

  testWidgets('同学最近评价渲染真实评价卡，不渲染旧 Feed', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    // 热门菜品占据首屏下半段，评价区在折叠区外，向上滚动后断言。
    final listFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          widget.axisDirection == AxisDirection.down &&
          widget.physics is AlwaysScrollableScrollPhysics,
    );
    expect(listFinder, findsOneWidget);
    await tester.fling(listFinder, const Offset(0, -900), 1200);
    await tester.pumpAndSettle();
    expect(find.text('同学最近评价'), findsOneWidget);
    expect(find.text('z同学'), findsOneWidget);
    expect(find.text('麻辣拌今天味道稳定，午饭高峰排了大概8分钟。'), findsOneWidget);
    expect(find.text('一食堂二楼'), findsWidgets);
    expect(find.text('旧 Feed 不应出现'), findsNothing);
    expect(find.text('想吃稳一点？'), findsNothing);
    expect(find.text('今天可以优先看看'), findsNothing);
  });

  testWidgets('热门菜品无数据时保留模块并显示轻量空态', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/home' && options.method == 'GET') {
        return _json(_homeWithoutDishesBody);
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio: dio));
    await tester.pumpAndSettle();

    final listFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          widget.axisDirection == AxisDirection.down &&
          widget.physics is AlwaysScrollableScrollPhysics,
    );
    await tester.scrollUntilVisible(
      find.text('热门菜品'),
      300,
      scrollable: listFinder,
    );
    expect(find.text('热门菜品'), findsOneWidget);
    expect(find.text('还没有菜品实拍'), findsOneWidget);
    expect(find.text('添加商家'), findsOneWidget);
    expect(find.text('旧 Feed 不应出现'), findsNothing);
  });

  testWidgets('无 FAB', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('暗色与大字号首页无溢出', (tester) async {
    await tester.pumpWidget(
      _buildApp(theme: ThemeData.dark(), textScale: 1.3),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final scrollableFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          widget.axisDirection == AxisDirection.down &&
          widget.physics is AlwaysScrollableScrollPhysics,
    );
    await tester.scrollUntilVisible(
      find.text('同学最近评价'),
      400,
      scrollable: scrollableFinder,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('同学最近评价'), findsOneWidget);
  });

  testWidgets('搜索时懒加载全量收录商家，即使未入选推荐流也能搜到', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    // 搜索未入选首页 Feed 的已收录店铺「川渝小吃」
    await tester.enterText(find.byType(TextField), '川渝小吃');
    await tester.pumpAndSettle();

    expect(find.text('川渝小吃（未进推荐流）'), findsOneWidget);
    expect(find.text('商家排行 #3'), findsOneWidget);
    // 搜索结果页不应展示首页 Feed 卡片
    expect(find.text('红烧牛肉面'), findsNothing);
  });

  testWidgets('搜索无结果时提供提交商家 CTA', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不存在的食堂');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到'), findsOneWidget);
    expect(find.text('提交商家'), findsOneWidget);
  });
}
