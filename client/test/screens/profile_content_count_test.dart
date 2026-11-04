import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/profile_screen.dart';
import 'package:shenliyuan/utils/app_navigator.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  int account = 20;
  int epoch = 0;
  @override
  User get user => User(
      id: account,
      studentId: 'test',
      nickname: '本地测试',
      createdAt: DateTime(2026));
  @override
  int get accountSessionEpoch => epoch;
  @override
  bool get isLoggedIn => true;
  @override
  Future<void> refreshUser() async {}
  void switchAccount(int id) {
    account = id;
    epoch++;
    notifyListeners();
  }
}

class _Adapter implements HttpClientAdapter {
  int posts = 16, market = 2, evaluations = 1, canteen = 0;
  int canteenStatus = 200;
  int status = 200;
  bool hold = false;
  final pending = <Completer<ResponseBody>>[];
  final requests = <RequestOptions>[];
  @override
  void close({bool force = false}) {}

  ResponseBody summary(int count) => response({
        'items': [],
        'total': count - 18,
        'content_counts': {'posts': 16, 'market': 2, 'evaluations': count - 18},
      });

  ResponseBody response(Object data, [int code = 200]) =>
      ResponseBody.fromString(jsonEncode(data), code, headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? stream, Future<void>? cancel) async {
    requests.add(o);
    if (o.path == '/user/canteen-reviews') {
      return response({
        'items': List.generate(canteen, (i) => {'id': i + 1, 'source': 'v2'}),
        'has_more': false,
      }, canteenStatus);
    }
    if (o.path == '/user/course-evaluations') {
      if (o.queryParameters['include_content_counts'] == 'true') {
        if (hold) {
          final gate = Completer<ResponseBody>();
          pending.add(gate);
          return gate.future;
        }
        if (status != 200) return response({'error': '本地失败'}, status);
        return response({
          'items': [],
          'total': evaluations,
          'content_counts': {
            'posts': posts,
            'market': market,
            'evaluations': evaluations,
          }
        });
      }
      return response({'items': [], 'total': evaluations, 'has_more': false});
    }
    if (o.path.endsWith('/posts')) return response([]);
    if (o.path.endsWith('/market-posts')) {
      return response({'items': [], 'total': 0});
    }
    return response(
        o.path.endsWith('/invitations') ? [] : {'count': 0, 'unread_count': 0});
  }
}

class _Harness {
  final _Adapter adapter;
  late final Dio dio;
  late final _Auth auth;
  late final ThemeProvider theme;
  late final EduProvider edu;
  late final MessageProvider messages;
  late final SocialProvider social;
  late final CourseEvaluationProvider evaluations;
  final active = ValueNotifier(true);
  _Harness(this.adapter) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    auth = _Auth(dio);
    theme = ThemeProvider(loadOnStart: false);
    edu = EduProvider(dio);
    messages = MessageProvider(dio, enableRealtime: false);
    social = SocialProvider(dio);
    evaluations = CourseEvaluationProvider(dio)..syncSessionUser(20);
  }
  Widget app() => MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider.value(value: edu),
            ChangeNotifierProvider.value(value: messages),
            ChangeNotifierProvider.value(value: social),
            ChangeNotifierProvider.value(value: evaluations),
            ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ],
          child: GoldenTestApp(
              home: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, value, __) => ProfileScreen(isActive: value))));
  void dispose() {
    auth.dispose();
    theme.dispose();
    edu.dispose();
    messages.dispose();
    social.dispose();
    evaluations.dispose();
    active.dispose();
  }
}

Future<_Harness> _show(WidgetTester tester, _Adapter adapter) async {
  await setGoldenViewport(tester, GoldenViewports.phone390x844);
  final h = _Harness(adapter);
  addTearDown(h.dispose);
  await tester.pumpWidget(h.app());
  await _advance(tester);
  return h;
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    currentHomeTabIndex.value = 4;
  });

  testWidgets('个人中心统计包含学科评价，16+2+1 显示19', (tester) async {
    final adapter = _Adapter();
    await _show(tester, adapter);
    await tester.pumpAndSettle();
    expect(find.text('19'), findsOneWidget);
    expect(
        adapter.requests.any((o) => o.path.endsWith('/posts/count')), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('再次进入个人中心更新新增或删除后的统计', (tester) async {
    final adapter = _Adapter();
    final h = await _show(tester, adapter);
    await tester.pumpAndSettle();
    adapter.evaluations = 2;
    h.active.value = false;
    await tester.pump();
    h.active.value = true;
    await _advance(tester);
    await tester.pumpAndSettle();
    expect(find.text('20'), findsOneWidget);
    adapter.market = 1;
    h.active.value = false;
    await tester.pump();
    h.active.value = true;
    await _advance(tester);
    await tester.pumpAndSettle();
    expect(find.text('19'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('食堂评价纳入总数，删除后再次进入同步减少', (tester) async {
    final adapter = _Adapter()..canteen = 2;
    final h = await _show(tester, adapter);
    await tester.pumpAndSettle();
    expect(find.text('21'), findsOneWidget);
    adapter.canteen = 1;
    h.active.value = false;
    await tester.pump();
    h.active.value = true;
    await _advance(tester);
    await tester.pumpAndSettle();
    expect(find.text('20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('食堂数量读取失败不显示三类之和冒充完整总数', (tester) async {
    final adapter = _Adapter()..canteenStatus = 503;
    final h = await _show(tester, adapter);
    await tester.pumpAndSettle();
    expect(find.text('-'), findsOneWidget);
    adapter
      ..canteenStatus = 200
      ..canteen = 2;
    h.active.value = false;
    await tester.pump();
    h.active.value = true;
    await _advance(tester);
    await tester.pumpAndSettle();
    expect(find.text('21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计失败保持未知，恢复后重新读取，不显示错误的零', (tester) async {
    final adapter = _Adapter()..status = 503;
    final h = await _show(tester, adapter);
    await tester.pumpAndSettle();
    expect(find.text('-'), findsOneWidget);
    adapter.status = 200;
    h.active.value = false;
    await tester.pump();
    h.active.value = true;
    await _advance(tester);
    await tester.pumpAndSettle();
    expect(find.text('19'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账号 A→B→A 旧统计晚返回不能覆盖最新数量', (tester) async {
    final adapter = _Adapter()..hold = true;
    final h = await _show(tester, adapter);
    h.auth.switchAccount(21);
    await _advance(tester);
    h.auth.switchAccount(20);
    await _advance(tester);
    expect(adapter.pending.length, greaterThanOrEqualTo(3));
    adapter.pending.last.complete(adapter.summary(20));
    await tester.pumpAndSettle();
    expect(find.text('20'), findsOneWidget);
    for (final gate in adapter.pending.take(adapter.pending.length - 1)) {
      gate.complete(adapter.summary(99));
    }
    await tester.pumpAndSettle();
    expect(find.text('20'), findsOneWidget);
    expect(find.text('99'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
