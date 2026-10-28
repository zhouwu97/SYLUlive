import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/config/water_post_taxonomy.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
import 'package:shenliyuan/services/poll_service.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class SessionAuth extends AuthProvider {
  SessionAuth(super.dio) : super(loadStoredAuth: false);
  int epoch = 0;
  @override
  int get accountSessionEpoch => epoch;
}

Map<String, dynamic> pollJson() => {
      'id': 301,
      'board_id': 1,
      'author_id': 2,
      'title': '周末校园活动选哪个？',
      'content': '匿名投票，结果结束后公开',
      'post_type': 'poll',
      'content_kind': 'poll',
      'created_at': '2026-10-28T00:00:00Z',
      'poll_meta': {
        'id': 17,
        'post_id': 301,
        'category': 'campus_life',
        'ends_at': '2099-01-01T00:00:00Z',
        'remaining_seconds': 3600,
        'results_visibility': 'after_end',
        'can_vote': false,
        'options': [
          {'id': 41, 'text': '校园散步', 'sort_order': 0},
          {'id': 42, 'text': '读书交流', 'sort_order': 1},
        ],
      },
    };

Widget app(Dio dio,
        {Post? initialPost,
        AuthProvider? auth,
        ThemeMode mode = ThemeMode.light,
        double scale = 1,
        bool split = false}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
            create: (_) => auth ?? AuthProvider(dio, loadStoredAuth: false)),
        ChangeNotifierProvider(
            create: (_) => PostProvider(dio, enableCache: false)),
        ChangeNotifierProvider(create: (_) => PollProvider(PollService(dio))),
      ],
      child: RepaintBoundary(
        key: const ValueKey('poll-recovery-canvas'),
        child: GoldenTestApp(
            themeMode: mode,
            textScaler: TextScaler.linear(scale),
            home: PostDetailScreen(
                postId: 301,
                initialPost: initialPost,
                isDesktopSplitMode: split,
                hideBackButton: split)),
      ),
    );

void main() {
  setUpAll(loadTestFonts);
  testWidgets('通用详情请求失败后点击重试恢复投票', (tester) async {
    var fail = true;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.path == '/posts/301' && fail) {
          h.reject(DioException(
              requestOptions: o, type: DioExceptionType.connectionError));
          return;
        }
        h.resolve(Response(
            requestOptions: o,
            statusCode: 200,
            data: o.path.endsWith('/replies')
                ? {'replies': [], 'total': 0}
                : pollJson()));
      }));
    await tester.pumpWidget(app(dio));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(PollDetailScreen), findsOneWidget);
    expect(find.text('校园散步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧账号的通用详情响应不能切入投票或污染缓存', (tester) async {
    final gate = Completer<void>();
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
        requests.add(o.path);
        if (o.path == '/posts/301') await gate.future;
        h.resolve(Response(
            requestOptions: o,
            statusCode: 200,
            data: o.path.endsWith('/replies')
                ? {'replies': [], 'total': 0}
                : pollJson()));
      }));
    final auth = SessionAuth(dio);
    await tester.pumpWidget(app(dio, auth: auth));
    await tester.pump();
    auth.epoch++;
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PollDetailScreen), findsNothing);
    expect(requests, isNot(contains('/polls/17')));
    final context = tester.element(find.byType(PostDetailScreen));
    expect(context.read<PostProvider>().postFor(301), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  test('投票分类不回退成校园生活且不进入普通发布分类', () {
    expect(waterCategoryLabelOf('poll'), '投票');
    expect(isValidWaterPostCategory('poll'), isFalse);
    expect(waterCategoryLabelOf('campus_life'), '校园生活');
  });

  for (final profile in [
    ('light', ThemeMode.light, 1.0),
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3)
  ]) {
    testWidgets('仅帖子 ID 入口恢复投票与匿名选项 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final gate = Completer<void>();
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
          requests.add(o.path);
          if (o.path == '/posts/301') {
            expect(o.queryParameters['capabilities'], 'poll_v1');
            await gate.future;
          }
          h.resolve(Response(
              requestOptions: o,
              statusCode: 200,
              data: o.path.endsWith('/replies')
                  ? {'replies': [], 'total': 0}
                  : pollJson()));
        }));
      await tester.pumpWidget(app(dio, mode: profile.$2, scale: profile.$3));
      await tester.pump();
      expect(find.byType(PollDetailScreen), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PollDetailScreen), findsOneWidget);
      expect(requests, contains('/polls/17'));
      expect(requests, isNot(contains('/polls/301')));
      expect(find.text('校园散步'), findsOneWidget);
      expect(find.text('读书交流'), findsOneWidget);
      expect(find.text('校园投票'), findsOneWidget);
      expect(find.text('版块：校园生活'), findsNothing);
      expect(tester.takeException(), isNull);
      const output = String.fromEnvironment('POLL_QA_OUTPUT');
      if (output.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('poll-recovery-canvas')));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(output).create(recursive: true);
          await File('$output/${profile.$1}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
    });
  }

  testWidgets('已知投票直接渲染，保留分栏参数与失败重试', (tester) async {
    var fail = true;
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        requests.add(o.path);
        if (o.path == '/polls/17' && fail) {
          h.reject(DioException(
              requestOptions: o, type: DioExceptionType.connectionError));
        } else {
          h.resolve(Response(
              requestOptions: o,
              statusCode: 200,
              data: o.path.endsWith('/replies')
                  ? {'replies': [], 'total': 0}
                  : pollJson()));
        }
      }));
    await tester.pumpWidget(
        app(dio, initialPost: Post.fromJson(pollJson()), split: true));
    await tester.pumpAndSettle();
    final screen =
        tester.widget<PollDetailScreen>(find.byType(PollDetailScreen));
    expect(screen.isDesktopSplitMode, isTrue);
    expect(screen.hideBackButton, isTrue);
    expect(find.text('校园散步'), findsOneWidget);
    expect(requests, isNot(contains('/posts/301')));
    fail = false;
    final dynamic state = tester.state(find.byType(PollDetailScreen));
    final Future<void> reload = state.reloadForTesting();
    await tester.pumpAndSettle();
    await reload;
    expect(requests.where((path) => path == '/polls/17'), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
