import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/admin/managed_ai_admin_tab.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/golden_test_app.dart';

class _Adapter implements HttpClientAdapter {
  int status = 200;
  List<Map<String, dynamic>> items = [];
  Completer<void>? gate;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancelFuture) async {
    expect(options.queryParameters['kind'], 'ai');
    await gate?.future;
    return ResponseBody.fromString(jsonEncode(items), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }
}

void main() {
  setUpAll(loadTestFonts);
  testWidgets('AI 归属、空状态、权限失败和重试', (tester) async {
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            fontFamily: 'NotoSansCJKsc', colorSchemeSeed: Colors.teal),
        home: RepaintBoundary(
            key: boundary,
            child: Scaffold(body: ManagedAIAdminTab(dio: dio)))));
    await tester.pumpAndSettle();
    expect(find.text('尚无用户创建的 AI'), findsOneWidget);
    adapter.status = 403;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要超级管理员权限'), findsOneWidget);
    adapter.status = 200;
    adapter.items = [
      {
        'id': 'AI-demo',
        'name': '小鱼',
        'owner_id': 7,
        'owner_name': '创建者',
        'enabled': true
      }
    ];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('小鱼'), findsOneWidget);
    expect(find.text('归属于 创建者 · 用户 #7'), findsOneWidget);
    expect(find.text('AI 已启用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../scratch/managed-ai-admin-20261111.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    dio.close();
  });

  testWidgets('切换账号时旧请求不能覆盖新 AI 列表', (tester) async {
    final old = _Adapter()
      ..gate = Completer<void>()
      ..items = [
        {'name': '旧AI'}
      ];
    final current = _Adapter()
      ..items = [
        {'name': '新AI', 'id': 'AI-new', 'owner_name': '新创建者', 'owner_id': 8}
      ];
    final oldDio = Dio()..httpClientAdapter = old;
    final newDio = Dio()..httpClientAdapter = current;
    Widget app(Dio dio) =>
        GoldenTestApp(home: Scaffold(body: ManagedAIAdminTab(dio: dio)));
    await tester.pumpWidget(app(oldDio));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(app(newDio));
    await tester.pumpAndSettle();
    expect(find.text('新AI'), findsOneWidget);
    old.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('旧AI'), findsNothing);
    expect(find.text('新AI'), findsOneWidget);
    expect(tester.takeException(), isNull);
    oldDio.close();
    newDio.close();
  });

  for (final dark in [false, true]) {
    testWidgets('所属 AI 窄屏大字号 ${dark ? '深色' : '浅色'}', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adapter = _Adapter()
        ..items = [
          {
            'name': '长名字的校园小鱼',
            'id': 'AI-00000000-0000-0000-0000-000000000001',
            'owner_name': '创建者同学的长昵称',
            'owner_id': 7
          }
        ];
      final dio = Dio()..httpClientAdapter = adapter;
      final boundary = GlobalKey();
      await tester.pumpWidget(GoldenTestApp(
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        textScaler: const TextScaler.linear(1.8),
        home: RepaintBoundary(
            key: boundary, child: Scaffold(body: ManagedAIAdminTab(dio: dio))),
      ));
      await tester.pumpAndSettle();
      expect(find.text('长名字的校园小鱼'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
            '../scratch/bot-full-regression-20261111/所属AI-${dark ? '深色' : '浅色'}.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      dio.close();
    });
  }
}
