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
import 'package:shenliyuan/screens/admin/admin_feedback_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Api {
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
  final filters = <String>[];
  bool fail = false;
  bool empty = false;
  Completer<void>? gate;

  _Api() {
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.endsWith('/stats')) {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'pending_count': 2,
          'waiting_user_count': 1,
          'testing_count': 0,
          'unviewed_count': 0,
        }));
        return;
      }
      final filter = options.queryParameters['status_filter'] as String;
      filters.add(filter);
      final requestGate = gate;
      final requestFail = fail;
      await requestGate?.future;
      if (requestFail) {
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.connectionError));
        return;
      }
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'tickets': empty
            ? []
            : List.generate(
                12,
                (i) => {
                      'id': i + 1,
                      'ticket_no': 'fixture-${i + 1}',
                      'user_id': 1,
                      'title': '$filter 工单 ${i + 1}',
                      'status': 'pending',
                      'admin_viewed': true,
                      'created_at': '2026-10-25T08:00:00Z',
                      'updated_at': '2026-10-25T08:00:00Z',
                    }),
        'has_more': false,
      }));
    }));
  }
}

Future<List<int>> _capture(
    WidgetTester tester, GlobalKey key, Offset point, String name) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final offset = (point.dy.round() * image.width + point.dx.round()) * 4;
      final directory = Platform.environment['BACKGROUND_QA_DIR'];
      if (directory != null) {
        await Directory(directory).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
      return List.generate(4, (i) => bytes.getUint8(offset + i));
    } finally {
      image.dispose();
    }
  }))!;
}

Future<({ThemeProvider theme, GlobalKey capture})> _pump(
    WidgetTester tester, _Api api, String profile) async {
  await setGoldenViewport(
      tester,
      profile == 'wide'
          ? GoldenViewports.phone390x844
          : GoldenViewports.phone360x800);
  final theme = ThemeProvider(loadOnStart: false);
  await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
  await theme.setFrostedGlass(true);
  await theme.setComponentOpacity(.7);
  addTearDown(theme.dispose);
  final capture = GlobalKey();
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: theme),
      ChangeNotifierProvider(
          create: (_) => AuthProvider(api.dio, loadStoredAuth: false)),
    ],
    child: RepaintBoundary(
        key: capture,
        child: GoldenTestApp(
          themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          textScaler: profile == 'large'
              ? GoldenTextProfile.large.scaler
              : TextScaler.noScaling,
          disableAnimations: profile == 'reduced',
          home: const AdminFeedbackScreen(),
        )),
  ));
  await tester.pumpAndSettle();
  final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
  await tester
      .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
  await tester.pumpAndSettle();
  return (theme: theme, capture: capture);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'wide', 'dark', 'large', 'reduced']) {
    testWidgets('$profile 工单筛选材质、按压与回退', (tester) async {
      final api = _Api();
      final env = await _pump(tester, api, profile);
      final tabs = find.byType(TabBar);
      final surface =
          find.ancestor(of: tabs, matching: find.byType(AppCardSurface));
      expect(surface, findsOneWidget, reason: '筛选栏必须使用共用玻璃表面');
      expect(
          find.descendant(of: surface, matching: find.byType(BackdropFilter)),
          findsOneWidget);
      final material =
          find.ancestor(of: tabs, matching: find.byType(Material)).first;
      expect(tester.widget<Material>(material).clipBehavior, isNot(Clip.none));
      final overlay = (tester.widget<TabBar>(tabs).overlayColor ??
              TabBarTheme.of(tester.element(tabs)).overlayColor)!
          .resolve({WidgetState.pressed})!;
      expect(overlay.r, overlay.g);
      expect(overlay.g, overlay.b, reason: '按压层使用中性反馈，不绘制绿色块');
      final before = await _capture(
          tester, env.capture, const Offset(2, 300), '$profile-idle');
      final gesture = await tester
          .startGesture(tester.getCenter(find.widgetWithText(Tab, '待受理')));
      await tester.pump(const Duration(milliseconds: 80));
      final pressed = await _capture(
          tester, env.capture, const Offset(2, 300), '$profile-pressed');
      expect(pressed, before, reason: '按压不能向筛选栏之外绘制状态层');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(api.filters.last, 'pending');
      expect(find.text('pending 工单 1'), findsOneWidget);
      await _capture(
          tester, env.capture, const Offset(2, 300), '$profile-selected');
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(
          (list.childrenDelegate as SliverChildBuilderDelegate)
              .addRepaintBoundaries,
          isFalse);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(list.controller!.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
      await env.theme.setComponentOpacity(.35);
      await tester.pumpAndSettle();
      final filterColor = tester
          .widgetList<Container>(
              find.descendant(of: surface, matching: find.byType(Container)))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .map((d) => d.color)
          .whereType<Color>();
      expect(filterColor.any((c) => (c.a - .35).abs() < .01), isTrue);
      await env.theme.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      await env.theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('工单加载、失败重试、空结果及快速切换仍可恢复', (tester) async {
    final api = _Api();
    await _pump(tester, api, 'light');
    api.fail = true;
    await tester.tap(find.widgetWithText(Tab, '未查看'));
    await tester.pumpAndSettle();
    expect(find.text('网络连接异常'), findsOneWidget);
    api.fail = false;
    api.gate = Completer<void>();
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.text('unviewed 工单 1'), findsOneWidget);
    api.empty = true;
    await tester.tap(find.widgetWithText(Tab, '待受理'));
    await tester.pumpAndSettle();
    expect(find.text('暂无符合条件的工单'), findsOneWidget);
    api.empty = false;
    api.gate = Completer<void>();
    final previous = api.gate!;
    await tester.tap(find.widgetWithText(Tab, '处理中'));
    await tester.pump(const Duration(milliseconds: 400));
    api.gate = null;
    await tester.drag(find.byType(TabBar), const Offset(-140, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(Tab, '待补充'));
    await tester.pumpAndSettle();
    expect(find.text('waiting_user 工单 1'), findsOneWidget);
    previous.complete();
    await tester.pumpAndSettle();
    expect(find.text('processing 工单 1'), findsNothing);
    expect(find.text('waiting_user 工单 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
