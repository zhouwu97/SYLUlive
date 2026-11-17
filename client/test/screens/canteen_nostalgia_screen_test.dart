import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_nostalgia_screen.dart';
import 'package:shenliyuan/screens/admin_canteen_operations_screen.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends Fake with ChangeNotifier implements AuthProvider {
  final String role;
  _Auth(this.role);
  @override
  int get accountSessionEpoch => 0;
  @override
  User get user => User(
      id: 7,
      studentId: 'fixture',
      nickname: '测试账号',
      createdAt: DateTime(2026),
      role: role);
}

Widget _app(Dio dio, Widget screen,
        {String role = 'user',
        bool dark = false,
        double scale = 1,
        GlobalKey? capture}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider<AuthProvider>(create: (_) => _Auth(role))
      ],
      child: MaterialApp(
          theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: 'NotoSansCJKsc'),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: RepaintBoundary(key: capture, child: screen)),
    );

const _offline = {
  'id': 2,
  'name': '记忆里的面馆',
  'is_offline': true,
  'rating_count': 12,
  'average_star': 4.6,
  'location_area': '一食堂',
  'location_floor': '二楼'
};

void main() {
  setUpAll(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('怀旧存档 $profile 真实渲染，不显示排名或普通用户维护入口', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.queryParameters['status'], 'offline');
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: [
          _offline,
          {'id': 1, 'name': '营业店'}
        ]));
      }));
      final capture = GlobalKey();
      await tester.pumpWidget(_app(dio, const CanteenNostalgiaScreen(),
          dark: profile == 'dark',
          scale: profile == 'large-text' ? 1.8 : 1,
          capture: capture));
      await tester.pumpAndSettle();
      expect(find.text('记忆里的面馆'), findsOneWidget);
      expect(find.text('营业店'), findsNothing);
      expect(find.textContaining('历史评分 4.6'), findsOneWidget);
      expect(find.text('维护资料'), findsNothing);
      expect(tester.takeException(), isNull);
      final dir = Platform.environment['CANTEEN_QA_DIR'];
      if (dir != null) {
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            final bytes =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            await Directory(dir).create(recursive: true);
            await File('$dir/nostalgia-$profile.png')
                .writeAsBytes(bytes.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    });
  }

  testWidgets('怀旧加载、失败重试、空态与离页旧响应', (tester) async {
    final dio = Dio();
    final pending = Completer<void>();
    var calls = 0;
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      calls++;
      if (calls == 1) {
        await pending.future;
        handler.reject(DioException(requestOptions: options));
      } else {
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: []));
      }
    }));
    await tester.pumpWidget(_app(dio, const CanteenNostalgiaScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有怀旧食堂'), findsOneWidget);
    final late = Completer<void>();
    dio.interceptors.clear();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      await late.future;
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: [_offline]));
    }));
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    late.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final role in ['admin', 'super_admin']) {
    testWidgets('运营页 $role 对怀旧资料的修改与恢复入口', (tester) async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'items': [_offline]
        }));
      }));
      await tester.pumpWidget(
          _app(dio, const AdminCanteenOperationsScreen(), role: role));
      await tester.pumpAndSettle();
      expect(find.byTooltip('管理「记忆里的面馆」'),
          role == 'super_admin' ? findsOneWidget : findsNothing);
      if (role == 'super_admin') {
        await tester.tap(find.byTooltip('管理「记忆里的面馆」'));
        await tester.pumpAndSettle();
      }
      expect(find.text('恢复营业'),
          role == 'super_admin' ? findsOneWidget : findsNothing);
      expect(find.textContaining('仅超级管理员可维护'), findsOneWidget);
    });
  }
}
