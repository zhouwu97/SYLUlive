import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_dish_list_screen.dart';

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

Widget _wrap(String dishesJson, {bool offline = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async => _json(dishesJson, 200));
  return ChangeNotifierProvider(
    create: (_) => CanteenProvider(dio),
    child: MaterialApp(
      home: CanteenDishListScreen(
        canteenId: 1,
        canteenName: '秀香园美食',
        offline: offline,
      ),
    ),
  );
}

Future<void> _pumpList(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('0 实拍菜品不渲染占位卡，有实拍菜品保留', (tester) async {
    await _pumpList(
      tester,
      _wrap(
        '[{"id":1,"name":"9块钱","cover_image":"/uploads/a.jpg","photo_count":1},'
        '{"id":2,"name":"13块钱","cover_image":"","photo_count":0}]',
      ),
    );

    expect(find.text('9块钱'), findsOneWidget);
    expect(find.text('13块钱'), findsNothing);
  });

  testWidgets('菜品都在但全部无实拍时展示空态提示', (tester) async {
    await _pumpList(
      tester,
      _wrap(
        '[{"id":2,"name":"13块钱","cover_image":"","photo_count":0},'
        '{"id":3,"name":"15块钱","cover_image":"","photo_count":0}]',
      ),
    );

    expect(find.text('暂无菜品实拍'), findsOneWidget);
    expect(find.text('13块钱'), findsNothing);
    expect(find.text('15块钱'), findsNothing);
  });

  testWidgets('完全没有菜品时保留收录引导', (tester) async {
    await _pumpList(tester, _wrap('[]'));

    expect(find.text('暂无收录菜品'), findsOneWidget);
    expect(find.text('发表食堂评价时填写菜品名称即可自动收录'), findsOneWidget);
  });
}
