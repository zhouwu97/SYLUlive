import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/admin/managed_ai_admin_tab.dart';
import '../helpers/load_test_fonts.dart';

class _Adapter implements HttpClientAdapter {
  int status = 200;
  List<Map<String, dynamic>> items = [];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancelFuture) async {
    expect(options.queryParameters['kind'], 'ai');
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
}
