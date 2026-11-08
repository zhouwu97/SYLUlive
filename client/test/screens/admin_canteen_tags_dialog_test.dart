import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/canteen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/admin_canteen_tags_dialog.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;
  Adapter(this.handler);
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);
}

ResponseBody response(String body, int status) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [
        body.startsWith('{') ? Headers.jsonContentType : 'text/plain'
      ]
    });
void main() {
  setUpAll(loadTestFonts);

  testWidgets('管理员设置位置和标签，失败后可重试', (tester) async {
    var loads = 0, saves = 0;
    Map<String, dynamic>? sent;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = Adapter((request) async {
      if (request.method == 'GET') {
        loads++;
        return loads == 1
            ? response('{"error":"failed"}', 500)
            : response(
                '{"location_area":"一食堂","location_floor":"一楼","tags":null}',
                200);
      }
      sent = request.data is String
          ? jsonDecode(request.data as String) as Map<String, dynamic>
          : Map<String, dynamic>.from(request.data as Map);
      saves++;
      return saves == 1
          ? response('{"error":"保存失败"}', 500)
          : response('{}', 200);
    });
    final shop = Canteen(
        id: 1,
        name: '测试店',
        image: '',
        verified: true,
        createdBy: 1,
        ratingCount: 0,
        averageStar: 0);
    await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => CanteenProvider(dio),
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                AdminCanteenTagsDialog(canteen: shop)),
                        child: const Text('打开')))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('加载标签失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('卫生干净'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败'), findsOneWidget);
    expect(sent!['tags'], ['clean']);
    expect(sent!['location_floor'], '一楼');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenTagsDialog), findsNothing);
  });

  for (final failure in [
    (
      status: 404,
      body: '404 page not found',
      message: '当前服务尚未支持店铺标签管理，请更新服务后重试'
    ),
    (status: 404, body: '{"error":"店铺不存在"}', message: '店铺不存在'),
    (
      status: 401,
      body: '{"message":"unauthorized"}',
      message: '登录已失效，请重新登录后再试'
    ),
    (status: 403, body: '{"message":"forbidden"}', message: '当前账号没有管理店铺标签的权限'),
  ]) {
    testWidgets('加载错误区分 ${failure.status} ${failure.message}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      var attempts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = Adapter((request) async {
        attempts++;
        return attempts == 1
            ? response(failure.body, failure.status)
            : response(
                '{"location_area":"一食堂","location_floor":"二楼","tags":null}',
                200);
      });
      await tester.pumpWidget(
          _dialogApp(dio, textScaler: const TextScaler.linear(1.3)));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text(failure.message), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('二楼'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
    });
  }

  testWidgets('深色模式显示接口未上线原因并可取消', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter =
        Adapter((_) async => response('404 page not found', 404));
    await tester.pumpWidget(_dialogApp(dio, themeMode: ThemeMode.dark));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('当前服务尚未支持店铺标签管理，请更新服务后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenTagsDialog), findsNothing);
  });

  testWidgets('手动标签最多三个，保存时拦截重复提交和返回', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final pending = Completer<ResponseBody>();
    var saves = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = Adapter((request) async {
      if (request.method == 'GET') {
        return response(
            '{"location_area":"一食堂","location_floor":"二楼","tags":["clean","good_value","taste_good"]}',
            200);
      }
      saves++;
      return pending.future;
    });
    await tester
        .pumpWidget(_dialogApp(dio, textScaler: const TextScaler.linear(1.3)));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final chip =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, '分量足'));
    expect(chip.onSelected, isNull);
    expect(find.text('已选择 3/3 个标签，按选择顺序展示'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await Navigator.of(tester.element(find.byType(AdminCanteenTagsDialog)))
        .maybePop();
    await tester.pump();
    expect(find.byType(AdminCanteenTagsDialog), findsOneWidget);
    expect(saves, 1);
    pending.complete(response('{}', 200));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenTagsDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账号切换后旧请求不能恢复可编辑状态', (tester) async {
    final pending = Completer<ResponseBody>();
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = Adapter((_) => pending.future);
    final auth = _TestAuth();
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth, child: _dialogApp(dio)));
    await tester.tap(find.text('打开'));
    await tester.pump();
    auth.switchSession();
    pending.complete(response(
        '{"location_area":"一食堂","location_floor":"二楼","tags":null}', 200));
    await tester.pumpAndSettle();
    expect(find.text('账号或管理权限已变更，请关闭后重新打开'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });
}

class _TestAuth extends ChangeNotifier implements AuthProvider {
  int generation = 1;
  @override
  int get sessionGeneration => generation;
  @override
  User get user => User(
      id: 1,
      studentId: 'test',
      nickname: '管理员',
      role: 'admin',
      createdAt: DateTime(2026));
  void switchSession() {
    generation++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _dialogApp(
  Dio dio, {
  ThemeMode themeMode = ThemeMode.light,
  TextScaler textScaler = TextScaler.noScaling,
}) =>
    ChangeNotifierProvider(
      create: (_) => CanteenProvider(dio),
      child: GoldenTestApp(
        themeMode: themeMode,
        textScaler: textScaler,
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showAppDialog<void>(
                          context: context,
                          builder: (_) => AdminCanteenTagsDialog(
                                canteen: Canteen(
                                    id: 34,
                                    name: '川渝椒香',
                                    image: '',
                                    verified: true,
                                    createdBy: 1,
                                    ratingCount: 0,
                                    averageStar: 0),
                              )),
                      child: const Text('打开'),
                    ))),
      ),
    );
