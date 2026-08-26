import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';
import 'package:shenliyuan/widgets/canteen/canteen_detail_skeleton.dart';
import 'package:shenliyuan/widgets/canteen/canteen_status_image.dart';

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

ResponseBody _json(String body, int status) {
  return ResponseBody.fromString(body, status, headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  });
}

String _detailJson({
  List<Map<String, String>> ratings = const [],
  int ratingCount = 0,
}) {
  final ratingsJson = ratings
      .map((r) =>
          '{"id":${r['id'] ?? 1},"user_id":2,"user_name":"同学A",'
          '"comment":"${r['comment'] ?? '好吃'}","star":${r['star'] ?? 5},'
          '"images":"[]","helpful_count":1,"unhelpful_count":0,'
          '"created_at":"2026-07-22"}')
      .join(',');
  return '''
  {
    "canteen": {"id":1,"name":"我家有面","image":"/uploads/a.jpg","verified":true,"created_by":1},
    "ratings": [$ratingsJson],
    "rating_count": $ratingCount,
    "average_star": 5.0,
    "my_rating": null
  }
  ''';
}

Widget _buildApp(
  Dio dio, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  String initialImage = '',
  bool initialOffline = false,
  String? heroTag,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: CanteenDetailScreen(
              canteenId: 1,
              canteenName: '我家有面',
              dishCount: 2,
              dishPhotoCount: 5,
              initialImage: initialImage,
              initialOffline: initialOffline,
              heroTag: heroTag,
            ),
          );
        },
      ),
    ),
  );
}

Dio _dioWith(String detailBody) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens/1' && options.method == 'GET') {
      return _json(detailBody, 200);
    }
    return _json('{"error":"not found"}', 404);
  });
  return dio;
}

void main() {
  testWidgets('首屏加载保留入口封面 Hero 目标', (tester) async {
    final pending = Completer<ResponseBody>();
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return pending.future;
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      _buildApp(
        dio,
        initialImage: '/uploads/ranking-cover.jpg',
        initialOffline: true,
        heroTag: 'canteen-1',
      ),
    );
    await tester.pump();

    final hero = find.byWidgetPredicate(
      (widget) => widget is Hero && widget.tag == 'canteen-1',
    );
    expect(hero, findsOneWidget);
    expect(find.byType(CanteenDetailSkeleton), findsOneWidget);
    expect(find.byType(CanteenStatusImage), findsOneWidget);
    expect(
      tester
          .widget<CanteenStatusImage>(find.byType(CanteenStatusImage))
          .offline,
      isTrue,
    );

    pending.complete(_json(_detailJson(), 200));
    await tester.pumpAndSettle();
    expect(hero, findsOneWidget);
    expect(find.byType(CanteenDetailSkeleton), findsNothing);
  });

  testWidgets('首次进入显示骨架而非中央 spinner', (tester) async {
    final dio = _dioWith(_detailJson());
    await tester.pumpWidget(_buildApp(dio));
    await tester.pump();

    // 请求未返回时：页面骨架（无全屏 CircularProgressIndicator）
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('我家有面'), findsOneWidget);
  });

  testWidgets('切换筛选不出现全屏 loading，Hero/信息区保持', (tester) async {
    final dio = _dioWith(_detailJson(ratingCount: 2));
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    // 点击「有图」筛选
    await tester.tap(find.text('有图'));
    await tester.pump();

    // 页面不消失：店名仍在（无 full-screen loading）
    expect(find.text('我家有面'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 不出现全屏 loading Scaffold
    expect(find.text('加载失败'), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('快速切换筛选时陈旧响应不覆盖新状态', (tester) async {
    // 可控响应：记录每个请求的 filter，允许乱序完成
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final pending = <({String filter, Completer<ResponseBody> completer})>[];
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        final filter =
            options.queryParameters['review_filter']?.toString() ?? 'all';
        final completer = Completer<ResponseBody>();
        pending.add((filter: filter, completer: completer));
        return completer.future;
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));

    // 等待首个请求发出
    for (var i = 0; i < 50 && pending.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(pending, isNotEmpty, reason: '首个请求未发出');

    // 首个请求（all）先返回
    pending[0].completer.complete(_json(_detailJson(ratingCount: 3), 200));
    await tester.pumpAndSettle();
    expect(find.text('用户评价'), findsOneWidget);

    // 点击「有图」→ 请求 A（with_image，慢）
    await tester.ensureVisible(find.text('有图'));
    await tester.pump();
    await tester.tap(find.text('有图'), warnIfMissed: true);
    for (var i = 0; i < 50 &&
        !pending.any((r) => r.filter == 'with_image'); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // 再点「高分」→ 请求 B（high，快）
    // 注意：A 未返回期间评价区顶部有 indeterminate 进度条动画，
    // 不能用 pumpAndSettle，用离散 pump。
    await tester.ensureVisible(find.text('高分'));
    await tester.pump();
    await tester.tap(find.text('高分'), warnIfMissed: true);
    for (var i = 0; i < 50 && !pending.any((r) => r.filter == 'high'); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    // ignore: avoid_print
    print('pending filters: ${pending.map((r) => r.filter).toList()}');
    expect(pending.any((r) => r.filter == 'high'), isTrue,
        reason: '高分请求未发出');
    final requestB = pending.firstWhere((r) => r.filter == 'high');
    final requestA = pending.firstWhere((r) => r.filter == 'with_image');

    // 请求 B 先返回（空）→ 数据落地后进度条消失，可安全 settle
    requestB.completer.complete(_json(_detailJson(ratingCount: 0), 200));
    await tester.pumpAndSettle();
    expect(find.text('暂无高分评价'), findsOneWidget);

    // 请求 A（with_image，带数据）晚到 → 必须被 generation 丢弃
    requestA.completer
        .complete(_json(_detailJson(ratingCount: 1, ratings: [
          {'id': '9', 'comment': '带图评价', 'star': '5'},
        ]), 200));
    await tester.pumpAndSettle();

    // 仍停留在「高分」空态，未被陈旧 with_image 响应覆盖
    expect(find.text('暂无高分评价'), findsOneWidget);
    expect(find.text('带图评价'), findsNothing);
  });

  testWidgets('商家详情页收起时只有一个贡献内容入口', (tester) async {
    final dio = _dioWith(_detailJson());
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson(), 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    // 菜品空态仍保留信息，但新增动作统一收进底部贡献入口。
    expect(find.text('还没有菜品实拍'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsNothing);
    expect(find.text('贡献内容'), findsOneWidget);
    expect(find.text('添加一条新的商家评价...'), findsNothing);
    expect(find.text('添加'), findsNothing);

    await tester.tap(find.text('贡献内容'));
    await tester.pumpAndSettle();
    expect(find.text('你想贡献什么？'), findsOneWidget);
    expect(find.text('写商家评价'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsOneWidget);
  });

  testWidgets('暗色与大字号下贡献入口面板无溢出', (tester) async {
    final dio = _dioWith(_detailJson());
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson(), 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      _buildApp(
        dio,
        brightness: Brightness.dark,
        textScaler: const TextScaler.linear(1.3),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('贡献内容'), findsOneWidget);

    await tester.tap(find.text('贡献内容'));
    await tester.pumpAndSettle();

    expect(find.text('写商家评价'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选请求失败后回滚标签并提示，不拿旧数据冒充新筛选', (tester) async {
    // 初始请求（all）成功；之后任何筛选请求都返回 500（provider 解析为 {}）
    var detailCalls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        detailCalls++;
        if (detailCalls == 1) {
          return _json(_detailJson(ratingCount: 2), 200);
        }
        return _json('{"error":"internal"}', 500);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();
    expect(find.text('用户评价'), findsOneWidget);

    // 点击「有图」→ 请求失败
    await tester.ensureVisible(find.text('有图'));
    await tester.pump();
    await tester.tap(find.text('有图'));
    await tester.pumpAndSettle();

    // 标签回滚到「全部」：有图不再选中（其文字颜色回到非选中态由选中态校验）
    // 核心断言：筛选值已回滚 → 内容仍是全部评价（rating_count=2 显示）
    expect(find.text('· 2'), findsOneWidget);
    // 失败提示
    expect(find.text('刷新失败，请重试'), findsOneWidget);
  });

  testWidgets('快速切换且最新请求失败：回滚到最后成功 applied 状态，而非瞬时 previous', (tester) async {
    // 场景：all 成功 → with_image 挂起 → high 发出且失败 → with_image stale
    // 最终必须回到 all（数据与标签一致）
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final pending = <({String filter, Completer<ResponseBody> completer})>[];
    var highFailed = false;
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        final filter =
            options.queryParameters['review_filter']?.toString() ?? 'all';
        if (filter == 'high') {
          highFailed = true;
          return _json('{"error":"internal"}', 500);
        }
        final completer = Completer<ResponseBody>();
        pending.add((filter: filter, completer: completer));
        return completer.future;
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    for (var i = 0; i < 50 && pending.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(pending, isNotEmpty, reason: '首个 all 请求未发出');
    pending[0].completer.complete(_json(_detailJson(ratingCount: 3), 200));
    await tester.pumpAndSettle();

    // 点击「有图」→ with_image 挂起
    await tester.ensureVisible(find.text('有图'));
    await tester.pump();
    await tester.tap(find.text('有图'), warnIfMissed: true);
    for (var i = 0; i < 50 &&
        !pending.any((r) => r.filter == 'with_image'); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // 再点「高分」→ high 请求立即失败（500）
    await tester.ensureVisible(find.text('高分'));
    await tester.pump();
    await tester.tap(find.text('高分'), warnIfMissed: true);
    for (var i = 0; i < 50 && !highFailed; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(highFailed, isTrue, reason: 'high 请求未发出');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // high 失败 → 回滚到 applied（all）：评分计数恢复为 all 数据
    expect(find.text('· 3'), findsOneWidget);
    expect(find.text('刷新失败，请重试'), findsOneWidget);

    // with_image 随后返回 200 但 stale → 必须被丢弃，不覆盖 all
    final withImageReq = pending.firstWhere((r) => r.filter == 'with_image');
    withImageReq.completer.complete(_json(_detailJson(ratingCount: 1, ratings: [
      {'id': '9', 'comment': '带图评价', 'star': '5'},
    ]), 200));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // 仍停留在 all：数据未被带图评价覆盖
    expect(find.text('· 3'), findsOneWidget);
    expect(find.text('带图评价'), findsNothing);
  });

  testWidgets('320px 宽度渲染无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dio = _dioWith(_detailJson(ratingCount: 2));
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('评价项不使用独立卡片而是 divider 分隔', (tester) async {
    final dio = _dioWith(
      _detailJson(
        ratings: [
          {'id': '1', 'comment': '小面好吃', 'star': '5'},
          {'id': '2', 'comment': '夯爆了', 'star': '4'},
        ],
        ratingCount: 2,
      ),
    );
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    expect(find.text('小面好吃'), findsOneWidget);
    expect(find.text('夯爆了'), findsOneWidget);
    // 星级简化为单星数字，不出现五个重复星
    expect(find.byIcon(Icons.star_rounded), findsWidgets);
    // 无独立卡片容器
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('首屏加载失败时展示重新加载按钮与错误提示，点击重试可恢复数据', (tester) async {
    var callCount = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        callCount++;
        if (callCount == 1) {
          return _json('{"error":"network error"}', 500);
        }
        return _json(_detailJson(ratingCount: 1), 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    // 验证：显示错误提示与重新加载按钮
    expect(find.widgetWithText(FilledButton, '重新加载'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);

    // 点击“重新加载”
    await tester.tap(find.widgetWithText(FilledButton, '重新加载'));
    await tester.pumpAndSettle();

    // 验证：重试成功，正常渲染食堂详情与评价区
    expect(find.text('我家有面'), findsOneWidget);
    expect(find.text('用户评价'), findsOneWidget);
    expect(callCount, 2);
  });
}
