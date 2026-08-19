import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_dish_detail_screen.dart';

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

Widget _buildApp({required String detailJson, bool isAdmin = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
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
  });
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

  testWidgets('1/3 显示上传入口状态', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [{"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"}]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('实拍图库 1 / 3'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsOneWidget);
    expect(find.text('实拍资料已完善'), findsNothing);
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
    await tester.longPress(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.text('管理已发布实拍'), findsOneWidget);
    expect(find.textContaining('上传者：真实的李同学'), findsOneWidget);
    expect(find.text('下架此实拍（释放名额）'), findsOneWidget);

    // 点击下架
    await tester.tap(find.text('下架此实拍（释放名额）'));
    await tester.pumpAndSettle();
  });
}
