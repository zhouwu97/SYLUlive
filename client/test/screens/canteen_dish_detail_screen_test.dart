import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_dish_detail_screen.dart';

import '../helpers/mock_public_image_http.dart';

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

Future<ResponseBody> Function(RequestOptions options) _handlerFor(
    String detailJson,
    {String? reviewsJson}) {
  return (options) async {
    if (options.path == '/canteens/1/dishes/12') {
      return _json(detailJson, 200);
    }
    if (options.path == '/canteens/dishes/12/reviews' && reviewsJson != null) {
      return _json(reviewsJson, 200);
    }
    if (options.path == '/canteens/dish-photos/1') {
      return _json(
          '{"id":1,"dish_id":12,"dish_name":"锅包肉","file_id":100,"image":"/uploads/a.jpg","uploader_id":2,"uploader_name":"真实的李同学","status":"approved","created_at":"2026-08-13"}',
          200);
    }
    if (options.path == '/canteens/dish-photos/1/archive' &&
        options.method == 'POST') {
      return _json('{"message":"已下架","photo_id":1}', 200);
    }
    return _json('{"error":"not found"}', 404);
  };
}

Widget _buildApp({
  required String detailJson,
  bool isAdmin = false,
  String? reviewsJson,
  Future<ResponseBody> Function(RequestOptions options)? handler,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter =
      FakeAdapter(handler ?? _handlerFor(detailJson, reviewsJson: reviewsJson));
  final user = isAdmin
      ? User(
          id: 1,
          studentId: 'admin',
          nickname: '管理员',
          role: 'admin',
          createdAt: DateTime.now(),
        )
      : null;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _FakeAuthProvider(user),
      ),
    ],
    child: const MaterialApp(
      home: CanteenDishDetailScreen(
        canteenId: 1,
        dishId: 12,
        dishName: '锅包肉',
        canteenName: '一食堂二楼',
      ),
    ),
  );
}

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  final User? _user;
  _FakeAuthProvider([this._user]);

  @override
  User? get user => _user;

  @override
  bool get isLoggedIn => _user != null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('实拍不再有 3 张名额：已有多张时仍保留评价入口，并提示只展示最新几张', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 8,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"},
          {"id":3,"image":"/uploads/c.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('实拍资料已完善'), findsNothing);
    expect(find.text('评价这道菜'), findsOneWidget);
    expect(find.text('共 8 张实拍，展示最新 3 张'), findsOneWidget);
    expect(find.textContaining('上传新照片'), findsOneWidget);
  });

  testWidgets('没有实拍时引导评价时上传', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 0,
        "photos": []
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('0 人评价中提到 · 0 张同学真实实拍'), findsOneWidget);
    expect(find.textContaining('评价「锅包肉」时上传照片'), findsOneWidget);
  });

  testWidgets('空地址实拍不渲染占位大图，计数按有效实拍统计', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 2,
        "photos": [
          {"id":1,"image":"","created_at":"2026-08-13"},
          {"id":2,"image":"   ","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('0 人评价中提到 · 0 张同学真实实拍'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.textContaining('评价「锅包肉」时上传照片'), findsOneWidget);
  });

  testWidgets('实拍地址混合有效与空白时只渲染有效项', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 2,
        "photos": [
          {"id":1,"image":"","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('0 人评价中提到 · 1 张同学真实实拍'), findsOneWidget);
    final networkImages = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(networkImages.any((img) => img.imageUrl.contains('b_v1_medium.jpg')),
        isTrue);
    expect(networkImages.every((img) => !img.imageUrl.contains('invalid')),
        isTrue);
  });

  testWidgets('实拍 404（数据库有记录但文件丢失）确认后移除并回落上传引导', (tester) async {
    const detailJson = '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [{"id":1,"image":"/uploads/missing.jpg","created_at":"2026-08-13"}]
      }
    ''';
    await tester.runAsync(
        () => installMockPublicImageHttp(apiHandler: _handlerFor(detailJson)));
    addTearDown(uninstallMockPublicImageHttp);

    await tester.pumpWidget(_buildApp(detailJson: detailJson));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    // 计数从 1 回落到 0，404 大占位图不再展示
    expect(find.text('0 人评价中提到 · 0 张同学真实实拍'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.textContaining('评价「锅包肉」时上传照片'), findsOneWidget);
  });

  testWidgets('实拍瞬时故障（500）不移除，保留图片位等待重试', (tester) async {
    const detailJson = '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [{"id":1,"image":"/uploads/flaky.jpg","created_at":"2026-08-13"}]
      }
    ''';
    await tester.runAsync(
        () => installMockPublicImageHttp(apiHandler: _handlerFor(detailJson)));
    addTearDown(uninstallMockPublicImageHttp);

    await tester.pumpWidget(_buildApp(detailJson: detailJson));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    // 计数不回落，图片位保留为瞬时故障占位（含变体→原图回退层）
    expect(find.text('0 人评价中提到 · 1 张同学真实实拍'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is CachedNetworkImage &&
          w.imageUrl.contains('flaky_v1_medium.jpg')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });

  testWidgets('没人打分时不编造分数，也不出现星级', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 0,
        "photos": [],
        "rated_count": 0,
        "scores": {"average":0,"taste":0,"value":0,"portion":0}
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('还没有同学给这道菜打分，写评价时可以顺手打个分'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
  });

  testWidgets('有人打分时展示综合分与味道/性价比/分量三项', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 0,
        "photos": [],
        "rated_count": 2,
        "scores": {"average":4.32,"taste":4.5,"value":4.0,"portion":3.5}
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('4.3'), findsOneWidget);
    expect(find.text('2 人打分'), findsOneWidget);
    expect(find.text('味道'), findsOneWidget);
    expect(find.text('性价比'), findsOneWidget);
    expect(find.text('分量'), findsOneWidget);
    expect(find.text('4.5'), findsOneWidget);
    expect(find.text('3.5'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
  });

  testWidgets('评价超过 3 条时只预览 3 条并给出查看全部入口', (tester) async {
    String review(int id) =>
        '{"id":$id,"review_id":$id,"user_id":${id + 100},"user_name":"同学$id","comment":"第$id条",'
        '"review_source":"canteen_review_event","dish_taste_score":5,"dish_value_score":4,"portion_score":3}';
    await tester.pumpWidget(_buildApp(
      detailJson:
          '{"dish":{"id":12,"name":"锅包肉","canteen_id":1},"photos":[],"photo_count":0}',
      reviewsJson:
          '{"items":[${review(1)},${review(2)},${review(3)}],"count":3,"total":7,"has_more":true}',
    ));
    await tester.pumpAndSettle();

    expect(find.text('同学1：第1条'), findsOneWidget);
    expect(find.text('同学3：第3条'), findsOneWidget);
    expect(find.text('味道 5 · 性价比 4 · 分量 3'), findsNWidgets(3));
    expect(find.text('查看全部 7 条评价'), findsOneWidget);
  });

  testWidgets('菜品加载失败时显示原因与重新加载，重试成功后恢复', (tester) async {
    var fail = true;
    await tester.pumpWidget(_buildApp(
      detailJson: '',
      handler: (options) async {
        if (options.path == '/canteens/1/dishes/12') {
          return fail
              ? _json('{"error":"服务暂时不可用"}', 500)
              : _json(
                  '{"dish":{"id":12,"name":"锅包肉","canteen_id":1},"photos":[],"photo_count":0}',
                  200);
        }
        return _json('{"error":"not found"}', 404);
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('菜品加载失败'), findsOneWidget);
    expect(find.text('服务暂时不可用'), findsOneWidget);
    expect(find.text('评价这道菜'), findsNothing);

    fail = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('菜品加载失败'), findsNothing);
    expect(find.text('评价这道菜'), findsOneWidget);
  });

  testWidgets('未登录点“评价这道菜”提示登录', (tester) async {
    await tester.pumpWidget(_buildApp(
        detailJson:
            '{"dish":{"id":12,"name":"锅包肉","canteen_id":1},"photos":[],"photo_count":0}'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('评价这道菜'));
    await tester.pump();
    expect(find.text('请先登录后评价'), findsOneWidget);
  });

  testWidgets('所属商家下架时不显示评价入口', (tester) async {
    await tester.pumpWidget(_buildApp(
        detailJson:
            '{"dish":{"id":12,"name":"锅包肉","canteen_id":1,"canteen_operating_status":"offline"},"photos":[],"photo_count":0}'));
    await tester.pumpAndSettle();

    expect(find.text('评价这道菜'), findsNothing);
    expect(find.text('所属商家已下架，暂不能新增菜品实拍或评价'), findsOneWidget);
  });

  testWidgets('管理员身份展示下架治理提示并长按唤起管理弹窗展示真实上传者', (tester) async {
    await tester.pumpWidget(_buildApp(
      isAdmin: true,
      detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"}
        ]
      }
    ''',
    ));
    await tester.pumpAndSettle();

    expect(find.text('管理员提示：长按实拍图片可设为封面或下架'), findsOneWidget);
    expect(find.byTooltip('管理这道菜'), findsOneWidget);

    // 长按实拍图片唤起管理 Sheet
    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();

    expect(find.text('管理已发布实拍'), findsOneWidget);
    expect(find.textContaining('上传者：真实的李同学'), findsOneWidget);
    expect(find.text('设为封面'), findsOneWidget);
    expect(find.text('下架此实拍'), findsOneWidget);

    // 点击下架
    await tester.tap(find.text('下架此实拍'));
    await tester.pumpAndSettle();
  });
}
