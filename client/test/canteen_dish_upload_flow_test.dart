import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';

/// 覆盖「第一张菜品实拍」完整闭环（P0）：
/// 空图鉴 → 点击上传 CTA → 直接打开上传 Sheet（dish_name 模式）
/// → 输入菜名 → 选图上传 → 提交请求 body 必须包含 dish_name。
///
/// 通过替换 ImagePickerPlatform 实例驱动真实 ImageUploadWidget 流程，
/// 再断言 dish-photos 请求的 body 字段。

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

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    return XFile.fromData(
      Uint8List.fromList(List.filled(32, 7)),
      name: 'dish.jpg',
      path: 'dish.jpg',
    );
  }
}

const _detailJson = '''
{
  "canteen": {"id":1,"name":"我家有面","image":"/uploads/a.jpg","verified":true,"created_by":1},
  "ratings": [],
  "rating_count": 0,
  "average_star": 0.0,
  "my_rating": null
}
''';

void main() {
  setUp(() {
    ImagePickerPlatform.instance = _FakeImagePickerPlatform();
  });

  testWidgets('空图鉴上传 CTA 直接打开 dish_name 上传 Sheet', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson, 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      if (options.path == '/upload' && options.method == 'POST') {
        return _json('{"url":"/uploads/dish.jpg","file_id":9527}', 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ],
        child: const MaterialApp(
          home: CanteenDetailScreen(
            canteenId: 1,
            canteenName: '我家有面',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空图鉴：CTA 可见
    expect(find.text('上传菜品实拍'), findsOneWidget);
    await tester.ensureVisible(find.text('上传菜品实拍'));
    await tester.pump();
    await tester.tap(find.text('上传菜品实拍'));
    await tester.pumpAndSettle();

    // 直接打开上传 Sheet（未经由菜品列表页）
    expect(find.text('给这道菜起个名字'), findsOneWidget);
    expect(find.text('输入菜名，例如：锅包肉'), findsOneWidget);
  });

  testWidgets('输入菜名并选图后提交，请求 body 含 dish_name', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    Map<String, dynamic>? dishPhotoBody;
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson, 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      if (options.path == '/upload' && options.method == 'POST') {
        return _json('{"url":"/uploads/dish.jpg","file_id":9527}', 200);
      }
      if (options.path == '/canteens/1/dish-photos' &&
          options.method == 'POST') {
        dishPhotoBody = options.data as Map<String, dynamic>;
        return _json('{"message":"已提交审核","photo":{"id":9}}', 201);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ],
        child: const MaterialApp(
          home: CanteenDetailScreen(
            canteenId: 1,
            canteenName: '我家有面',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开上传 Sheet
    await tester.ensureVisible(find.text('上传菜品实拍'));
    await tester.pump();
    await tester.tap(find.text('上传菜品实拍'));
    await tester.pumpAndSettle();

    // 输入菜名（dish_name 模式）
    await tester.enterText(find.byType(TextField), '锅包肉');
    await tester.pump();

    // 选择图片：触发 ImageUploadWidget 的相册入口
    await tester.tap(find.text('添加实拍'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();

    // 图片上传成功后，提交按钮可用
    final submitButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('提交审核'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(submitButton.onPressed, isNotNull);

    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();

    // 关键断言：请求 body 含 dish_name=锅包肉，且无 dish_id
    expect(dishPhotoBody, isNotNull);
    expect(dishPhotoBody!['dish_name'], '锅包肉');
    expect(dishPhotoBody!.containsKey('dish_id'), isFalse);
    expect(dishPhotoBody!['file_id'], 9527);
  });
}
