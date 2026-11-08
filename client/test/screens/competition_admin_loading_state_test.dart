import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/competition/competition_admin_center_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _catalog = {
  'items': [
    {'id': 1, 'is_active': true, 'dataset_version': 'fixture-2026'}
  ]
};
const _events = {'items': [], 'total': 0, 'total_pages': 1};

Widget _app(Dio dio, ThemeProvider appearance, {bool dark = false}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
            create: (_) => AuthProvider(dio, loadStoredAuth: false)),
        ChangeNotifierProvider.value(value: appearance),
      ],
      child: GoldenTestApp(
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          textScaler: TextScaler.linear(dark ? 1.3 : 1),
          home: const CompetitionAdminCenterScreen()),
    );

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final folder = Platform.environment['BACKGROUND_QA_DIR'];
  if (folder == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(folder).create(recursive: true);
    await File('$folder/$name.png').writeAsBytes(data.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    testWidgets('目录及赛事未确定前不显示错误管理模式，刷新保持模式 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      await appearance.setBackgroundImage('morenbeijing.jpeg');
      await appearance.setFrostedGlass(true);
      var catalogGate = Completer<void>(), eventGate = Completer<void>();
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
          Object data = <String, Object>{};
          if (o.path == '/admin/competition-catalog/packages') {
            await catalogGate.future;
            data = _catalog;
          } else if (o.path == '/admin/competitions/events') {
            await eventGate.future;
            data = _events;
          } else if (o.path == '/competitions/categories') {
            data = [];
          }
          h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
        }));
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: capture, child: _app(dio, appearance, dark: dark)));
      await tester.pump();
      expect(find.text('正在读取竞赛目录…'), findsOneWidget);
      expect(find.text('AI导入'), findsNothing);
      expect(find.text('维护列表'), findsNothing);
      expect(find.text('草稿'), findsNothing);
      await _capture(tester, capture, 'admin-loading-$dark');
      catalogGate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('正在读取竞赛目录…'), findsOneWidget);
      expect(find.text('当前赛事'), findsNothing);
      eventGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('目录包'), findsOneWidget);
      expect(find.text('当前赛事'), findsWidgets);
      expect(find.text('AI导入'), findsNothing);
      expect(find.text('当前显示 0–0，共 0 条'), findsOneWidget);
      await _capture(tester, capture, 'admin-loaded-$dark');
      final button = find.ancestor(
          of: find.text('目录包'), matching: find.byType(OutlinedButton));
      final rect = tester.getRect(button);
      catalogGate = Completer<void>();
      eventGate = Completer<void>();
      await tester.tap(find.text('当前赛事').first);
      await tester.pump();
      expect(tester.getRect(button), rect);
      expect(find.text('AI导入'), findsNothing);
      catalogGate.complete();
      eventGate.complete();
      await tester.pumpAndSettle();
      expect(tester.getRect(button), rect);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('重复刷新时较旧目录结果不能切回旧管理模式', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone390x844);
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    final catalogs = <Completer<Object>>[];
    var eventRequests = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
        Object data = <String, Object>{};
        if (o.path == '/admin/competition-catalog/packages') {
          final gate = Completer<Object>();
          catalogs.add(gate);
          data = await gate.future;
        } else if (o.path == '/admin/competitions/events') {
          eventRequests++;
          data = _events;
        } else if (o.path == '/competitions/categories') {
          data = [];
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    await tester.pumpWidget(_app(dio, appearance));
    await tester.pump(const Duration(milliseconds: 10));
    catalogs.first.complete(_catalog);
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('当前赛事').first);
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(catalogs, hasLength(3));
    catalogs[2].complete({
      'items': [
        {'id': 2, 'is_active': true, 'dataset_version': '最新目录'}
      ]
    });
    await tester.pumpAndSettle();
    expect(find.text('最新目录'), findsOneWidget);
    catalogs[1].complete({'items': []});
    await tester.pumpAndSettle();
    expect(find.text('最新目录'), findsOneWidget);
    expect(find.text('AI导入'), findsNothing);
    expect(eventRequests, 2, reason: '旧加载不能再次请求旧模式列表');
    expect(tester.takeException(), isNull);
  });

  for (final malformed in [false, true]) {
    testWidgets('赛事列表失败不展示未确认模式，重试恢复 malformed=$malformed', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      var fail = true;
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          if (o.path == '/admin/competitions/events' && fail && !malformed) {
            h.reject(DioException(
                requestOptions: o,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: o, statusCode: 500)));
            return;
          }
          final Object data = switch (o.path) {
            '/admin/competition-catalog/packages' => _catalog,
            '/admin/competitions/events' => fail ? 'invalid events' : _events,
            '/competitions/categories' => [],
            _ => <String, Object>{},
          };
          h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
        }));
      await tester.pumpWidget(_app(dio, appearance));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('AI导入'), findsNothing);
      expect(find.text('目录包'), findsNothing);
      if (malformed) expect(find.text('竞赛列表数据解析失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('目录包'), findsOneWidget);
      expect(find.text('当前显示 0–0，共 0 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final status in [404, 403, 500]) {
    testWidgets('目录接口 $status 区分旧版兼容与错误，重试可恢复', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      var responseStatus = status;
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          if (o.path == '/admin/competition-catalog/packages' &&
              responseStatus != 200) {
            h.reject(DioException(
                requestOptions: o,
                type: DioExceptionType.badResponse,
                response:
                    Response(requestOptions: o, statusCode: responseStatus)));
            return;
          }
          final Object data = switch (o.path) {
            '/admin/competition-catalog/packages' => _catalog,
            '/admin/competitions/events' => _events,
            '/competitions/categories' => [],
            _ => <String, Object>{},
          };
          h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
        }));
      await tester.pumpWidget(_app(dio, appearance));
      await tester.pumpAndSettle();
      if (status == 404) {
        expect(find.text('AI导入'), findsWidgets);
        expect(find.text('维护列表'), findsOneWidget);
      } else {
        expect(find.text('AI导入'), findsNothing);
        expect(find.text('维护列表'), findsNothing);
        expect(find.text('重试'), findsOneWidget);
        responseStatus = 200;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(find.text('目录包'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
