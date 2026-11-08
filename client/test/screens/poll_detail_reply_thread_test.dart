import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
import 'package:shenliyuan/services/poll_service.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _output = String.fromEnvironment('POLL_REPLY_QA_OUTPUT');
const _label =
    String.fromEnvironment('POLL_REPLY_QA_LABEL', defaultValue: 'after');
const _canvas = ValueKey('poll-reply-qa-canvas');
final _sheet = find.byKey(const ValueKey('reply-thread-surface'));

Future<void> _capture(WidgetTester tester, String name) async {
  if (_output.isEmpty) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_canvas));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(_output).create(recursive: true);
    await File('$_output/$_label-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Map<String, dynamic> _poll() => {
      'id': 1,
      'title': '校园活动投票',
      'content': '周末更想参加哪种活动？',
      'author_id': 2,
      'post_type': 'poll',
      'content_kind': 'poll',
      'reply_count': 9,
      'poll_meta': {
        'id': 1,
        'post_id': 1,
        'selection_mode': 'single',
        'max_choices': 1,
        'status': 'active',
        'results_visible': true,
        'options': [
          {'id': 10, 'text': '校园运动', 'sort_order': 0, 'vote_count': 3},
          {'id': 11, 'text': '读书交流', 'sort_order': 1, 'vote_count': 2},
        ],
      },
    };

Map<String, dynamic> _reply(int id, String content, {bool root = false}) => {
      'id': id,
      'post_id': 1,
      'author_id': id,
      if (!root) 'parent_reply_id': 21,
      if (!root) 'reply_to_user_id': 21,
      if (!root) 'reply_to_reply_id': 21,
      if (!root) 'reply_to_name': '发起讨论的同学',
      'child_reply_count': root ? 8 : 0,
      'content': content,
      'created_at': '2026-11-03T08:00:00Z',
      'author': {
        'id': id,
        'nickname': root ? '发起讨论的同学' : '参与讨论的同学$id',
        'avatar': '',
      },
    };

class _ThreadAuth extends AuthProvider {
  _ThreadAuth(super.dio) : super(loadStoredAuth: false);
  int? account;
  int epoch = 0;

  @override
  User? get user => account == null
      ? null
      : User(
          id: account!,
          studentId: '',
          nickname: '测试账号',
          createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => account != null;
  @override
  int get accountSessionEpoch => epoch;

  void changeAccount(int? id) {
    account = id;
    epoch++;
    notifyListeners();
  }
}

class _Fixture {
  _Fixture({this.withPreviews = true, this.childCount = 8}) {
    auth = _ThreadAuth(dio);
    addTearDown(auth.dispose);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      Object? data;
      if (options.path.endsWith('/children')) {
        if (onChildren != null) {
          onChildren!(options, handler);
          return;
        }
        data = {
          'replies': [
            _reply(22, '第一条预览回复'),
            _reply(23, '第二条预览回复'),
            _reply(24, '之前无法看到的第三条回复'),
          ],
          'next_cursor': '',
        };
      } else if (options.path == '/polls/1') {
        data = _poll();
      } else if (options.path == '/posts/1/replies' &&
          options.method == 'GET') {
        data = {
          'replies': [
            {
              ..._reply(21, '想听听大家的建议', root: true),
              'child_reply_count': childCount
            },
            if (withPreviews) _reply(22, '第一条预览回复'),
            if (withPreviews) _reply(23, '第二条预览回复'),
          ],
          'next_cursor': '',
        };
      } else if (options.path == '/posts/1/replies' &&
          options.method == 'POST') {
        if (failSend) {
          _reject(options, handler, 503);
          return;
        }
        data = {..._reply(25, '我的后续回复'), 'reply_to_reply_id': 24};
      } else {
        handler.reject(DioException(requestOptions: options));
        return;
      }
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: data));
    }));
  }

  final dio = Dio();
  late final _ThreadAuth auth;
  final bool withPreviews;
  final int childCount;
  final requests = <RequestOptions>[];
  bool failSend = false;
  void Function(RequestOptions, RequestInterceptorHandler)? onChildren;
}

void _reject(RequestOptions options, RequestInterceptorHandler handler,
        int status) =>
    handler.reject(DioException(
      requestOptions: options,
      response: Response(
          requestOptions: options,
          statusCode: status,
          data: {'error': '回复暂时无法加载'}),
    ));

Widget _screen(_Fixture fixture,
        {ThemeMode theme = ThemeMode.light, double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: fixture.auth),
        ChangeNotifierProvider(
            create: (_) => PollProvider(PollService(fixture.dio))),
        ChangeNotifierProvider(create: (_) => PostProvider(fixture.dio)),
      ],
      child: RepaintBoundary(
        key: _canvas,
        child: GoldenTestApp(
          themeMode: theme,
          textScaler: TextScaler.linear(scale),
          home:
              PollDetailScreen(pollId: 1, initialPost: Post.fromJson(_poll())),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  final entry = find.text('共 8 条回复');
  expect(entry, findsOneWidget);
  await tester.ensureVisible(entry);
  await tester.pump();
  await tester.tap(entry);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _showInSheet(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 100,
      scrollable:
          find.descendant(of: _sheet, matching: find.byType(Scrollable)).first);
  await tester.ensureVisible(finder);
  await tester.pump();
}

void main() {
  setUpAll(() async {
    AppPreferencesStore.setMockInitialValues({});
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('投票评论显示真实回复总数并可打开预览之外的回复', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final fixture = _Fixture();
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _capture(tester, 'preview-light');
    await _open(tester);
    await tester.pumpAndSettle();

    expect(
        fixture.requests.where((r) => r.path.endsWith('/children')).length, 1);
    expect(find.text('评论详情'), findsOneWidget);
    expect(
        find.descendant(of: _sheet, matching: find.textContaining('第一条预览回复')),
        findsOneWidget);
    await _showInSheet(tester, find.textContaining('之前无法看到的第三条回复'));
    expect(find.textContaining('之前无法看到的第三条回复'), findsOneWidget);
    await _capture(tester, 'thread-light');
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有预览仍可打开讨论，分页按游标加载且不会重复显示', (tester) async {
    final fixture = _Fixture(withPreviews: false);
    fixture.onChildren = (options, handler) {
      final nextPage = options.queryParameters['cursor'] == 'page-2';
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'replies': [
          _reply(24, '第三条完整回复'),
          if (nextPage) _reply(25, '下一页的回复'),
        ],
        'next_cursor': nextPage ? '' : 'page-2',
      }));
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpAndSettle();
    await _showInSheet(tester, find.text('加载更多回复'));
    await tester.tap(find.text('加载更多回复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第三条完整回复'), findsOneWidget);
    expect(find.textContaining('下一页的回复'), findsOneWidget);
    expect(find.text('加载更多回复'), findsNothing);
    expect(fixture.requests.last.queryParameters['cursor'], 'page-2');
  });

  testWidgets('预览可点开讨论，选择子回复后沿用输入栏并保留失败草稿', (tester) async {
    final fixture = _Fixture()..failSend = true;
    fixture.auth.account = 7;
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.enterText(input, '我的后续回复');
    final preview = find.textContaining('第一条预览回复', findRichText: true);
    await tester.ensureVisible(preview);
    await tester.pump();
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(find.text('回复 @参与讨论的同学22'), findsOneWidget);
    final target = find.textContaining('之前无法看到的第三条回复');
    await _showInSheet(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(find.text('回复 @参与讨论的同学24'), findsOneWidget);
    final sheetInput = find.descendant(of: _sheet, matching: input);
    final sheetSend = find.descendant(
        of: _sheet,
        matching: find.byKey(const ValueKey('post-reply-send-button')));
    await tester.enterText(sheetInput, '我的后续回复');
    await tester.pump();
    await tester.tap(sheetSend);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(sheetInput).controller!.text, '我的后续回复');
    final request = fixture.requests.lastWhere((r) => r.method == 'POST');
    final fields = Map.fromEntries((request.data as FormData).fields);
    expect(fields['parent_reply_id'], '21');
    expect(fields['reply_to_reply_id'], '24');
    expect(fields['reply_to_user_id'], '24');
    fixture.failSend = false;
    await tester.tap(sheetSend);
    await tester.pumpAndSettle();
    final retried = fixture.requests.lastWhere((r) => r.method == 'POST');
    expect(
        retried.headers['Idempotency-Key'], request.headers['Idempotency-Key']);
    expect(tester.widget<TextField>(sheetInput).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    expect(find.text('共 9 条回复'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '我的后续回复');
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载失败保留预览，可重试并显示空态', (tester) async {
    final pending = Completer<void>();
    final fixture = _Fixture();
    var attempts = 0;
    fixture.onChildren = (options, handler) {
      attempts++;
      if (attempts == 1) {
        pending.future.then((_) => _reject(options, handler, 503));
      } else {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'replies': [], 'next_cursor': ''}));
      }
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await _showInSheet(tester, find.byType(CircularProgressIndicator));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
        find.descendant(of: _sheet, matching: find.textContaining('第一条预览回复')),
        findsOneWidget);
    await _capture(tester, 'loading');
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('回复暂时无法加载'), findsOneWidget);
    await _capture(tester, 'error');
    await _showInSheet(tester, find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('暂无回复'), findsOneWidget);
    expect(
        find.descendant(of: _sheet, matching: find.textContaining('第一条预览回复')),
        findsNothing);
    await _capture(tester, 'empty');
  });

  testWidgets('分页失败从同一游标重试，权限失败不展示旧子回复', (tester) async {
    final fixture = _Fixture();
    var attempts = 0;
    fixture.onChildren = (options, handler) {
      attempts++;
      if (attempts == 2) {
        _reject(options, handler, 403);
        return;
      }
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'replies': [
          _reply(
              attempts == 1 ? 24 : 25, attempts == 1 ? '第一页完整回复' : '恢复权限后的回复')
        ],
        'next_cursor': attempts == 1 ? 'next' : '',
      }));
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpAndSettle();
    await _showInSheet(tester, find.text('加载更多回复'));
    await tester.tap(find.text('加载更多回复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第一页完整回复'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(fixture.requests.last.queryParameters['cursor'], 'next');
    expect(find.textContaining('恢复权限后的回复'), findsOneWidget);
  });

  testWidgets('无子回复的评论保持直接回复，不请求楼中楼', (tester) async {
    final fixture = _Fixture(withPreviews: false, childCount: 0);
    fixture.auth.account = 7;
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    expect(find.textContaining('条回复'), findsNothing);
    await tester.tap(find.text('想听听大家的建议'));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(find.text('回复 @发起讨论的同学'), findsOneWidget);
    expect(fixture.requests.any((r) => r.path.endsWith('/children')), isFalse);
  });

  testWidgets('关闭后旧请求不能覆盖再次打开的讨论', (tester) async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    var attempts = 0;
    fixture.onChildren = (options, handler) {
      attempts++;
      if (attempts == 1) {
        gate.future.then((_) => handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: {
              'replies': [_reply(24, '已关闭页面的旧回复')]
            })));
      } else {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'replies': [_reply(25, '重新打开后的回复')]
        }));
      }
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('重新打开后的回复'), findsOneWidget);
    expect(find.textContaining('已关闭页面的旧回复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录周期变化后隐藏预览并忽略在途旧回复', (tester) async {
    final fixture = _Fixture();
    fixture.auth.account = 7;
    final gate = Completer<void>();
    fixture.onChildren = (options, handler) {
      gate.future.then((_) => handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'replies': [_reply(24, '旧登录周期的回复')]
          })));
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    fixture.auth.changeAccount(7);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('登录状态已变更，请重新打开评论'), findsOneWidget);
    expect(find.textContaining('旧登录周期的回复'), findsNothing);
    expect(
        find.descendant(of: _sheet, matching: find.textContaining('第一条预览回复')),
        findsNothing);
  });

  testWidgets('首次加载晚于发送完成时仍保留刚发送的回复', (tester) async {
    final fixture = _Fixture();
    fixture.auth.account = 7;
    final gate = Completer<void>();
    fixture.onChildren = (options, handler) {
      gate.future.then((_) => handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'replies': [_reply(24, '较早的回复')],
            'next_cursor': ''
          })));
    };
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    final input = find.descendant(
        of: _sheet, matching: find.byKey(const ValueKey('post-reply-input')));
    await tester.enterText(input, '我的后续回复');
    await tester.pump();
    await tester.tap(find.descendant(
        of: _sheet,
        matching: find.byKey(const ValueKey('post-reply-send-button'))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(fixture.requests.any((r) => r.method == 'POST'), isTrue);
    gate.complete();
    await tester.pumpAndSettle();
    await _showInSheet(tester, find.textContaining('我的后续回复'));
    expect(find.textContaining('我的后续回复'), findsOneWidget);
  });

  testWidgets('发送期间切换账号不回填旧账号的回复和计数', (tester) async {
    final fixture = _Fixture();
    fixture.auth.account = 7;
    final gate = Completer<void>();
    var sending = false;
    fixture.dio.interceptors.insert(0,
        InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.method == 'POST') {
        sending = true;
        await gate.future;
      }
      handler.next(options);
    }));
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpAndSettle();
    final input = find.descendant(
        of: _sheet, matching: find.byKey(const ValueKey('post-reply-input')));
    await tester.enterText(input, '我的后续回复');
    await tester.pump();
    await tester.tap(find.descendant(
        of: _sheet,
        matching: find.byKey(const ValueKey('post-reply-send-button'))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(sending, isTrue);
    fixture.auth.changeAccount(8);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('登录状态已变更，请重新打开评论'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    expect(find.text('共 8 条回复'), findsOneWidget);
    expect(find.text('共 9 条回复'), findsNothing);
  });

  testWidgets('评论详情在键盘和表情面板切换时保持输入可见', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final fixture = _Fixture();
    fixture.auth.account = 7;
    await tester.pumpWidget(_screen(fixture));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.pumpAndSettle();
    final input = find.descendant(
        of: _sheet, matching: find.byKey(const ValueKey('post-reply-input')));
    final composer = find.descendant(
        of: _sheet,
        matching: find.byKey(const ValueKey('post-reply-composer')));
    final originalBottom = tester.getBottomLeft(composer).dy;
    await tester.enterText(input, '切换输入方式时保留这份草稿');
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(originalBottom - tester.getBottomLeft(composer).dy, 300);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'keyboard');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: _sheet,
        matching: find.byKey(const ValueKey('post-reply-emoji-button'))));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: _sheet,
            matching: find.byKey(const ValueKey('post-reply-emoji-panel'))),
        findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '切换输入方式时保留这份草稿');
    expect(tester.takeException(), isNull);
    await _capture(tester, 'emoji');
  });

  for (final profile in [
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3),
    ('stress', ThemeMode.dark, 1.5),
  ]) {
    testWidgets('完整回复真实渲染 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final fixture = _Fixture();
      await tester
          .pumpWidget(_screen(fixture, theme: profile.$2, scale: profile.$3));
      await tester.pumpAndSettle();
      final entry = find.text('共 8 条回复');
      await tester.ensureVisible(entry);
      await tester.pump();
      expect(
          tester
              .getSize(
                  find.ancestor(of: entry, matching: find.byType(TextButton)))
              .height,
          greaterThanOrEqualTo(44));
      await _capture(tester, 'preview-${profile.$1}');
      await _open(tester);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byTooltip('关闭回复')).height,
          greaterThanOrEqualTo(44));
      await _capture(tester, 'thread-${profile.$1}');
      expect(tester.takeException(), isNull);
    });
  }
}
