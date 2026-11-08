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
import 'package:shenliyuan/screens/managed_bot_connections_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false) {
    dio.interceptors.clear();
  }
  int id = 7, epoch = 1;
  @override
  User get user => User(
      id: id, studentId: '', nickname: '合成创建者$id', createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  int get accountSessionEpoch => epoch;
  void switchAccount() {
    id++;
    epoch++;
    notifyListeners();
  }
}

Map<String, dynamic> _binding(
        {String id = 'active', String state = 'active'}) =>
    {
      'binding_id': id,
      'installation_name': state == 'active' ? '我的 AstrBot' : '旧的 AstrBot',
      'state': state,
      'scopes':
          'profile:read_minimal community:read actions:read_own community:propose community:bot_reply community:bot_post',
    };

Future<GlobalKey> _pump(WidgetTester tester, _Auth auth,
    {ThemeMode theme = ThemeMode.light, double scale = 1}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final key = GlobalKey();
  await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
    value: auth,
    child: RepaintBoundary(
      key: key,
      child: GoldenTestApp(
          themeMode: theme,
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          home: const ManagedBotConnectionsScreen()),
    ),
  ));
  await tester.pump();
  return key;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['BOT_CONNECTION_EVIDENCE'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> _show(WidgetTester tester, Finder target,
    [double delta = 180]) async {
  await tester.scrollUntilVisible(target, delta,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  testWidgets('有效连接先说明成功，连接码和历史均按需显示', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding(), _binding(id: 'old', state: 'revoked')]
      }));
    }));
    final key = await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _capture(tester, key, 'active-light');
    expect(find.text('已连接 AstrBot'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-device-code')), findsNothing);
    expect(find.text('旧的 AstrBot'), findsNothing);
    expect(find.textContaining('已授予：公开浏览、自动评论与回复、自动发帖'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _show(tester, find.text('历史连接（1）'));
    await tester.tap(find.text('历史连接（1）'));
    await tester.pumpAndSettle();
    expect(find.text('旧的 AstrBot'), findsOneWidget);
  });

  testWidgets('加载状态不显示未连接结论', (tester) async {
    final wait = Completer<void>();
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      await wait.future;
      handler
          .resolve(Response(requestOptions: request, data: {'bindings': []}));
    }));
    await _pump(tester, auth);
    expect(find.text('正在核对连接'), findsOneWidget);
    expect(find.textContaining('尚未连接'), findsNothing);
    wait.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('读取失败保持未知状态，不能说暂无连接', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.reject(DioException(requestOptions: request));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('连接状态暂未确认'), findsOneWidget);
    expect(find.textContaining('暂无连接'), findsNothing);
  });

  test('教程地址只派生于当前API origin，不接受凭据或任意协议', () {
    expect(
        astrBotConnectionGuideUri('https://fixture.invalid:8443/api')
            ?.toString(),
        'https://fixture.invalid:8443/web/connected-apps?guide=astrbot');
    expect(
        astrBotConnectionGuideUri('/api',
                pageUri: Uri.parse('https://app.invalid/current'))
            ?.toString(),
        'https://app.invalid/web/connected-apps?guide=astrbot');
    expect(astrBotConnectionGuideUri('http://127.0.0.1:8080/api')?.host,
        '127.0.0.1');
    for (final value in [
      '',
      'https://name:secret@fixture.invalid/api',
      'https://fixture.invalid/api?url=other',
      'https://fixture.invalid/api#other',
      'http://remote.invalid/api',
      'javascript:alert(1)',
      'file:///tmp/api',
      'not-a-configured-origin',
      '//remote.invalid/api'
    ]) {
      expect(astrBotConnectionGuideUri(value), isNull, reason: value);
    }
  });

  testWidgets('主动核对一次性连接码，可以取消且不改变现有连接', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') writes.add(request);
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding()]
      }));
    }));
    final key = await _pump(tester, auth);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-open-connection-request')));
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-device-code')));
    await tester.enterText(
        find.byKey(const ValueKey('bot-device-code')), 'ABCD-EFGH');
    await _capture(tester, key, 'request-open');
    await _show(tester, find.text('取消本次核对'));
    await tester.tap(find.text('取消本次核对'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-device-code')), findsNothing);
    expect(find.text('已连接 AstrBot'), findsOneWidget);
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺权限时原地补充授权，不重新连接也不连带个人查询', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    var scopes = 'profile:read_minimal content:read_own_public checkin:write';
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') {
        writes.add(request);
        scopes = ((request.data as Map)['scopes'] as List).join(' ');
      }
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {..._binding(), 'scopes': scopes, 'epoch': 3}
        ],
        'personal_data_enabled': false
      }));
    }));
    final key = await _pump(tester, auth);
    await tester.pumpAndSettle();
    final supplement = find.byKey(const ValueKey('bot-supplement-scopes'));
    await _show(tester, supplement);
    await tester.tap(supplement);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-scope-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-device-code')), findsNothing);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('bot-edit-scope-community:bot_post')))
            .value,
        isTrue);
    expect(
        tester
            .widget<CheckboxListTile>(find
                .byKey(const ValueKey('bot-edit-scope-academic:grades:read')))
            .value,
        isFalse);
    await _capture(tester, key, 'scope-editor-light');
    expect(writes, isEmpty);
    final save = find.byKey(const ValueKey('bot-save-scopes'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes.single.path, '/connected-apps/active/scopes');
    expect(writes.single.extra['expectedAuthUserId'], 7);
    final body = writes.single.data as Map;
    expect(body['expected_epoch'], 3);
    expect(
        (body['scopes'] as List).toSet(),
        containsAll(<String>[
          'community:read',
          'actions:read_own',
          'community:propose',
          'community:bot_reply',
          'community:bot_post',
          'checkin:write'
        ]));
    expect((body['scopes'] as List).any((s) => '$s'.startsWith('academic:')),
        isFalse);
    expect(find.textContaining('无需重新连接'), findsWidgets);
    expect(find.byKey(const ValueKey('bot-scope-editor')), findsNothing);
    expect(find.byKey(const ValueKey('bot-supplement-scopes')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改权限依赖不满足时不能保存，失败保留所选', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') {
        writes.add(request);
        handler.reject(DioException(
            requestOptions: request,
            response: Response(
                requestOptions: request,
                statusCode: 409,
                data: {'code': 'binding_conflict'})));
        return;
      }
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {..._binding(), 'epoch': 1}
        ]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    final edit = find.byKey(const ValueKey('bot-edit-scopes'));
    await _show(tester, edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final propose =
        find.byKey(const ValueKey('bot-edit-scope-community:propose'));
    await _show(tester, propose);
    await tester.tap(propose);
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('bot-save-scopes'));
    await _show(tester, save);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await _show(tester, propose, -180);
    await tester.tap(propose);
    await tester.pumpAndSettle();
    final post =
        find.byKey(const ValueKey('bot-edit-scope-community:bot_post'));
    await _show(tester, post);
    await tester.tap(post);
    await tester.pumpAndSettle();
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect((writes.single.data as Map)['scopes'],
        isNot(contains('community:bot_post')));
    expect(find.textContaining('连接状态已变化'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-scope-editor')), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(post).value, isFalse);
    expect(find.text('已连接 AstrBot'), findsOneWidget);
  });

  testWidgets('站点未开放的权限置灰且不预选', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') writes.add(request);
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {
            ..._binding(),
            'scopes': 'profile:read_minimal content:read_own_public',
            'epoch': 1
          }
        ],
        'personal_data_enabled': false,
        'proposals_enabled': true,
        'auto_reply_enabled': true,
        'auto_post_enabled': false,
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    final supplement = find.byKey(const ValueKey('bot-supplement-scopes'));
    await _show(tester, supplement);
    await tester.tap(supplement);
    await tester.pumpAndSettle();
    final post =
        find.byKey(const ValueKey('bot-edit-scope-community:bot_post'));
    await _show(tester, post);
    expect(tester.widget<CheckboxListTile>(post).value, isFalse);
    expect(tester.widget<CheckboxListTile>(post).onChanged, isNull);
    expect(find.text('站点尚未开放此功能，暂不能新增'), findsWidgets);
    final save = find.byKey(const ValueKey('bot-save-scopes'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final scopes = (writes.single.data as Map)['scopes'] as List;
    expect(scopes, contains('community:bot_reply'));
    expect(scopes, isNot(contains('community:bot_post')));
  });

  testWidgets('连接已断开时保存失败会刷新并关闭编辑区', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    var revoked = false;
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') {
        revoked = true;
        handler.reject(DioException(
            requestOptions: request,
            response: Response(
                requestOptions: request,
                statusCode: 409,
                data: {'code': 'binding_conflict'})));
        return;
      }
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {..._binding(state: revoked ? 'revoked' : 'active'), 'epoch': 1}
        ]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    final edit = find.byKey(const ValueKey('bot-edit-scopes'));
    await _show(tester, edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('bot-save-scopes'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-scope-editor')), findsNothing);
    expect(find.text('尚未连接 AstrBot'), findsOneWidget);
    expect(find.textContaining('连接状态已变化'), findsOneWidget);
  });

  testWidgets('断开说明影响，可以取消；确认后只撤销当前连接', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    var disconnected = false;
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') {
        writes.add(request);
        disconnected = true;
      }
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding(state: disconnected ? 'revoked' : 'active')]
      }));
    }));
    final key = await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _show(tester, find.text('断开连接'));
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('机器人账号与已发布内容保留'), findsOneWidget);
    await _capture(tester, key, 'disconnect-confirmation');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.text('已连接 AstrBot'), findsOneWidget);
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认断开'));
    await tester.pumpAndSettle();
    expect(writes.single.path, '/connected-apps/active/revoke');
    expect(writes.single.extra['expectedAuthUserId'], 7);
    expect(find.text('尚未连接 AstrBot'), findsOneWidget);
    expect(find.text('已连接 AstrBot'), findsNothing);
  });

  testWidgets('刷新失败保持未知，重试后重新核实连接', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    var count = 0;
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (++count == 2) {
        handler.reject(DioException(requestOptions: request));
        return;
      }
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding()]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新连接状态'));
    await tester.pumpAndSettle();
    expect(find.text('连接状态暂未确认'), findsOneWidget);
    expect(find.text('已连接 AstrBot'), findsNothing);
    expect(find.text('尚未连接 AstrBot'), findsNothing);
    await tester.tap(find.text('重新读取连接'));
    await tester.pumpAndSettle();
    expect(find.text('已连接 AstrBot'), findsOneWidget);
    expect(count, 3);
  });

  testWidgets('旧账号延迟连接列表不能覆盖新账号', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final first = Completer<void>();
    var count = 0;
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      final old = ++count == 1;
      if (old) await first.future;
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {..._binding(), 'installation_name': old ? '旧账号执行端' : '新账号执行端'}
        ]
      }));
    }));
    await _pump(tester, auth);
    auth.switchAccount();
    await tester.pumpAndSettle();
    first.complete();
    await tester.pumpAndSettle();
    expect(find.text('新账号执行端'), findsOneWidget);
    expect(find.text('旧账号执行端'), findsNothing);
    expect(find.byKey(const ValueKey('bot-device-code')), findsNothing);
  });

  testWidgets('切换账号会关闭旧账号的断开确认，不发送撤销', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final writes = <RequestOptions>[];
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') writes.add(request);
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding()]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _show(tester, find.text('断开连接'));
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    auth.switchAccount();
    await tester.pumpAndSettle();
    expect(find.text('确认断开'), findsNothing);
    expect(writes, isEmpty);
  });

  testWidgets('教程使用当前服务地址，打开失败可重试且不改授权', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    final calls = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add((call.arguments as Map)['url'] as String);
      return calls.length > 1;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final writes = <RequestOptions>[];
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method != 'GET') writes.add(request);
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [_binding()]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    final guide = find.text('查看 AstrBot 接入教程');
    await _show(tester, guide);
    await tester.tap(guide);
    await tester.pumpAndSettle();
    expect(find.textContaining('未能打开接入教程'), findsOneWidget);
    await tester.tap(guide);
    await tester.pumpAndSettle();
    expect(
        calls,
        List.filled(
            2, 'https://fixture.invalid/web/connected-apps?guide=astrbot'));
    expect(writes, isEmpty);
    expect(find.textContaining('未能打开接入教程'), findsNothing);
  });

  testWidgets('损坏连接响应不能显示绑定成功或暂无连接', (tester) async {
    final auth =
        _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
    addTearDown(auth.dispose);
    auth.dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.resolve(Response(requestOptions: request, data: {
        'bindings': [
          {'state': 'active', 'installation_name': 99}
        ]
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('连接状态暂未确认'), findsOneWidget);
    expect(find.text('已连接 AstrBot'), findsNothing);
    expect(find.text('尚未连接 AstrBot'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final profile in [
    (ThemeMode.dark, 1.0, 'dark'),
    (ThemeMode.light, 1.3, 'large'),
    (ThemeMode.dark, 1.5, 'dark-large')
  ]) {
    testWidgets('连接概览与教程可读不溢出 ${profile.$3}', (tester) async {
      final auth =
          _Auth(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
      addTearDown(auth.dispose);
      auth.dio.interceptors
          .add(InterceptorsWrapper(onRequest: (request, handler) {
        handler.resolve(Response(requestOptions: request, data: {
          'bindings': [_binding(), _binding(id: 'old', state: 'revoked')]
        }));
      }));
      final key =
          await _pump(tester, auth, theme: profile.$1, scale: profile.$2);
      await tester.pumpAndSettle();
      expect(find.text('已连接 AstrBot'), findsOneWidget);
      await _capture(tester, key, 'active-${profile.$3}');
      await _show(tester, find.text('查看 AstrBot 接入教程'));
      await _capture(tester, key, 'guide-${profile.$3}');
      expect(tester.takeException(), isNull);
    });
  }
}
