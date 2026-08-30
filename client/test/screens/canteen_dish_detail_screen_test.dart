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
    String detailJson) {
  return (options) async {
    if (options.path == '/canteens/1/dishes/12') {
      return _json(detailJson, 200);
    }
    if (options.path == '/canteens/dish-photos/1') {
      return _json('{"id":1,"dish_id":12,"dish_name":"锅包肉","file_id":100,"image":"/uploads/a.jpg","uploader_id":2,"uploader_name":"真实的李同学","status":"approved","created_at":"2026-08-13"}', 200);
    }
    if (options.path == '/canteens/dish-photos/1/archive' && options.method == 'POST') {
      return _json('{"message":"已下架","photo_id":1}', 200);
    }
    return _json('{"error":"not found"}', 404);
  };
}

Widget _buildApp({required String detailJson, bool isAdmin = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter(_handlerFor(detailJson));
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
  testWidgets('3/3 显示实拍资料已完善且无上传按钮', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 3,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"},
          {"id":3,"image":"/uploads/c.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('实拍图库 3 / 3'), findsOneWidget);
    expect(find.text('实拍资料已完善'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsNothing);
  });

  testWidgets('1/3 显示关联评价引导', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [{"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"}]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('0 人评价中提到 · 1 张同学真实实拍'), findsOneWidget);
    expect(find.textContaining('发表食堂评价时关联「锅包肉」'), findsOneWidget);
    expect(find.text('实拍资料已完善'), findsNothing);
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
    expect(find.textContaining('发表食堂评价时关联「锅包肉」'), findsOneWidget);
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
    expect(networkImages, hasLength(1));
    expect(networkImages.single.imageUrl, contains('b_v1_medium.jpg'));
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
    expect(find.textContaining('发表食堂评价时关联「锅包肉」'), findsOneWidget);
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
          w is CachedNetworkImage && w.imageUrl.contains('flaky_v1_medium.jpg')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });

  testWidgets('无星级评分展示', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 2,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    // 不出现 "评分" 字样
    expect(find.textContaining('评分'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
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

    expect(find.text('管理员提示：长按实拍图片可进行下架治理'), findsOneWidget);

    // 长按实拍图片唤起管理 Sheet
    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();

    expect(find.text('管理已发布实拍'), findsOneWidget);
    expect(find.textContaining('上传者：真实的李同学'), findsOneWidget);
    expect(find.text('下架此实拍（释放名额）'), findsOneWidget);

    // 点击下架
    await tester.tap(find.text('下架此实拍（释放名额）'));
    await tester.pumpAndSettle();
  });
}
