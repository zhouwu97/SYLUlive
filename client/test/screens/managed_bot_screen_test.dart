import '../helpers/active_backdrop_filters.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_scroll_behavior.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/screens/managed_bot_screen.dart';
import 'package:shenliyuan/screens/managed_bot_connections_screen.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false) {
    // UI 替身身份不写 AuthProvider 私有登录状态；由下方合成传输处理请求。
    dio.interceptors.clear();
  }
  int id = 7, epoch = 1;
  @override
  User get user =>
      User(id: id, studentId: '', nickname: '合成创建者', createdAt: DateTime(2026));
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

Map<String, dynamic> _policy() => {
      'public_read_enabled': true,
      'reply_enabled': false,
      'sticker_enabled': false,
      'post_enabled': false,
      'image_enabled': false,
      'allowed_post_types': ['campus_life', 'course_study'],
      'blocked_terms': <String>[],
      'block_links': true,
      'daily_reply_limit': 3,
      'min_reply_interval_minutes': 30,
    };

Map<String, dynamic> _status(Map<String, dynamic>? bot) => {
      'bot': bot == null ? null : {'avatar': '', 'policy': _policy(), ...bot},
      'policy_supported': true,
      'sections': [
        {'slug': 'campus_life', 'name': '校园生活'},
        {'slug': 'course_study', 'name': '课程学习'},
      ],
      'auto_reply_server_enabled': false,
      'auto_reply_authorized': false,
    };

class _Picker extends ImagePickerPlatform {
  XFile? file;
  Completer<XFile?>? pending;
  bool denied = false;
  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    if (denied) throw PlatformException(code: 'photo_access_denied');
    if (pending != null) return pending!.future;
    return file;
  }
}

Future<void> _pump(WidgetTester tester, _Auth auth,
    {ThemeMode theme = ThemeMode.light,
    double scale = 1,
    Key? boundary,
    ThemeProvider? appearance,
    Size viewport = GoldenViewports.phone360x800,
    Widget home = const ManagedBotScreen()}) async {
  await setGoldenViewport(tester, viewport);
  await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        if (appearance != null)
          ChangeNotifierProvider<ThemeProvider>.value(value: appearance)
      ],
      child: GoldenTestApp(
          themeMode: theme,
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          home: RepaintBoundary(
              key: boundary,
              child: Builder(
                  builder: (context) => ScrollConfiguration(
                        behavior: AppScrollBehavior(
                            frostedGlass:
                                context.watch<ThemeProvider?>()?.frostedGlass ??
                                    false),
                        child: home,
                      ))))));
  await tester.pump();
}

Future<void> _show(WidgetTester tester, Finder target, double delta) async {
  await tester.scrollUntilVisible(target, delta,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

Future<void> _openNativeRequest(WidgetTester tester) async {
  final opener = find.byKey(const ValueKey('bot-open-connection-request'));
  await _show(tester, opener, 180);
  await tester.tap(opener);
  await tester.pumpAndSettle();
  await _show(tester, find.byKey(const ValueKey('bot-device-code')), 180);
}

Future<void> _expand(WidgetTester tester, String key,
    {double delta = 200}) async {
  final target = find.byKey(ValueKey(key));
  await _show(tester, target, delta);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _capture(
    WidgetTester tester, GlobalKey boundary, String name) async {
  final folder = Platform.environment['BOT_UI_EVIDENCE'];
  if (folder == null) return;
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(folder).create(recursive: true);
      await File('$folder/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

double _surfaceAlpha(WidgetTester tester, String key) {
  final boxes = tester.widgetList<DecoratedBox>(find.descendant(
      of: find.byKey(ValueKey(key)), matching: find.byType(DecoratedBox)));
  return (boxes.first.decoration as BoxDecoration).color!.a;
}

Future<double> _appBarContrast(WidgetTester tester, GlobalKey boundary) async {
  final foreground = tester.widget<Text>(find.text('我的 AI 机器人')).style!.color!;
  return (await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // 标题与刷新图标之间的顶栏空白，读取实际壁纸/玻璃合成像素。
      final offset = (24 * image.width + 260) * 4;
      final backdrop = Color.fromARGB(
          rgba!.getUint8(offset + 3),
          rgba.getUint8(offset),
          rgba.getUint8(offset + 1),
          rgba.getUint8(offset + 2));
      final a = foreground.computeLuminance(), b = backdrop.computeLuminance();
      return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('100条与1分钟设置可读取保存，非法间隔禁用保存', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() { auth.dispose(); dio.close(); });
    final writes = <Map>[];
    final policy = {..._policy(), 'daily_reply_limit': 100, 'min_reply_interval_minutes': 1};
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes.add(Map.from(request.data as Map));
      handler.resolve(Response(requestOptions: request, data: _status({
        'bot_user_id':10, 'name':'活跃机器人', 'enabled':false, 'policy':policy
      })));
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth, theme:ThemeMode.dark, scale:1.5, boundary:boundary);
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-speech-toggle');
    final daily = find.byKey(const ValueKey('bot-daily-limit'));
    await _show(tester, daily, 180);
    expect(tester.widget<DropdownButton<int>>(daily).value, 100);
    await _capture(tester, boundary, 'app-expanded-quota-dark-large');
    final interval = find.byKey(const ValueKey('bot-interval'));
    await _show(tester, interval, 180);
    await tester.enterText(interval, '0');
    final save = find.byKey(const ValueKey('bot-save-policy'));
    await _show(tester, save, 180);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await _show(tester, interval, -180);
    await tester.enterText(interval, '1');
    await _show(tester, save, 180);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes.single['policy'], containsPair('daily_reply_limit',100));
    expect(writes.single['policy'], containsPair('min_reply_interval_minutes',1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final profile in [
    (ThemeMode.light, 1.0, 'light'),
    (ThemeMode.dark, 1.5, 'dark-large')
  ]) {
    testWidgets('后台状态真实展示且定时刷新不覆盖编辑草稿 ${profile.$3}', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      var requests = 0;
      var fail = false;
      var runtimeState = 'offline';
      final now = DateTime.now().toUtc().toIso8601String();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.path.endsWith('/bot/runtime')) {
          requests++;
          if (fail) {
            handler.reject(DioException(requestOptions: request));
            return;
          }
          handler.resolve(Response(requestOptions: request, data: {
            'runtime': {'state': runtimeState, 'last_read_at': now}
          }));
          return;
        }
        handler.resolve(Response(requestOptions: request, data: {
          ..._status({'bot_user_id': 10, 'name': '本人机器人', 'enabled': true}),
          'runtime_supported': true,
          'runtime': {
            'state': 'loading',
            'last_seen_at': now,
            'last_read_at': now,
            'last_action': {
              'kind': 'reply',
              'completed_at': now,
              'post_id': 1,
              'reply_id': 2
            }
          }
        }));
      }));
      final boundary = GlobalKey();
      await _pump(tester, auth,
          theme: profile.$1, scale: profile.$2, boundary: boundary);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '未保存的机器人名字');
      await _show(tester, find.text('后台运行：正在浏览'), 200);
      await _capture(tester, boundary, 'app-runtime-${profile.$3}');
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('后台运行：执行端离线或尚未连接'), findsOneWidget);
      expect(find.text('未保存的机器人名字'), findsOneWidget);
      fail = true;
      final refresh = find.byKey(const ValueKey('bot-refresh-runtime'));
      await _show(tester, refresh, 100);
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      await _capture(tester, boundary, 'app-runtime-focused-${profile.$3}');
      expect(tester.getSize(refresh).height, greaterThanOrEqualTo(44));
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('后台运行：尚未核验'), findsOneWidget);
      fail = false;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('后台运行：执行端离线或尚未连接'), findsOneWidget);
      runtimeState = 'scope_required';
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await _show(tester, find.textContaining('绑定只建立连接'), -100);
      expect(find.textContaining('已有的「本人公开帖子」是另一项权限'), findsOneWidget);
      expect(find.textContaining('/sylu-connect'), findsOneWidget);
      await _capture(tester, boundary, 'app-runtime-permission-${profile.$3}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('后台运行旧账号响应不能回填新账号，暂停由当前账号状态显示', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final pending = Completer<void>();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.path.endsWith('/bot/runtime')) {
        await pending.future;
        handler.resolve(Response(requestOptions: request, data: {
          'runtime': {'state': 'loading'}
        }));
        return;
      }
      handler.resolve(Response(requestOptions: request, data: {
        ..._status({
          'bot_user_id': auth.id + 10,
          'name': '账号${auth.id}',
          'enabled': auth.id == 7
        }),
        'runtime_supported': true,
        'runtime': {'state': auth.id == 7 ? 'loading' : 'paused'}
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    final refresh = find.byKey(const ValueKey('bot-refresh-runtime'));
    await _show(tester, refresh, 180);
    await tester.tap(refresh);
    await tester.pump();
    auth.switchAccount();
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();
    await _show(tester, find.text('后台运行：已暂停'), 180);
    expect(find.text('后台运行：正在浏览'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人查询关闭时说明原因，仅允许授权其余范围', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    Map? decision;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path.endsWith('/decision')) decision = request.data as Map;
      final data = request.path.endsWith('/lookup')
          ? {
              'consent_id': 'private-disabled-fixture',
              'installation_name': '合成助手',
              'installation_id': 'fixture-install',
              'user_code': 'ABCD-EFGH',
              'confirmation_nonce': 'fixture-nonce',
              'expires_at': '2099-01-01T00:00:00Z',
              'requested_scopes': [
                'community:read',
                'academic:grades:read',
                'academic:erke:read'
              ]
            }
          : {'bindings': [], 'personal_data_enabled': false};
      handler.resolve(Response(requestOptions: request, data: data));
    }));
    await _pump(tester, auth, home: const ManagedBotConnectionsScreen());
    await tester.pumpAndSettle();
    await _openNativeRequest(tester);
    await tester.enterText(
        find.byKey(const ValueKey('bot-device-code')), 'ABCD-EFGH');
    await tester.pump();
    await tester.tap(find.text('查看授权请求'));
    await tester.pumpAndSettle();
    expect(find.text('授权给 合成助手'), findsOneWidget);
    for (final scope in ['academic:grades:read', 'academic:erke:read']) {
      final box = tester
          .widget<CheckboxListTile>(find.byKey(ValueKey('bot-scope-$scope')));
      expect(box.value, false);
      expect(box.onChanged, isNull);
    }
    expect(find.text('服务端尚未开放个人查询，可先只授权其他权限。'), findsNWidgets(2));
    await _show(tester, find.byKey(const ValueKey('bot-consent-confirm')), 100);
    await tester.tap(find.byKey(const ValueKey('bot-consent-confirm')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('授权此助手'), 100);
    await tester.tap(find.text('授权此助手'));
    await tester.pumpAndSettle();
    expect(decision?['scopes'], ['community:read']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  setUpAll(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in [
    (false, 1.0, 'light'),
    (true, 1.0, 'dark'),
    (false, 1.3, 'large'),
    (true, 1.5, 'dark-large')
  ]) {
    final (dark, scale, label) = profile;
    testWidgets('机器人创建、暂停与隐私说明 $label', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      Map<String, dynamic>? bot;
      final writes = <Map>[];
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.method == 'POST') {
          final body = Map<String, dynamic>.from(request.data as Map);
          writes.add(body);
          bot = {
            'bot_user_id': 10,
            'name': body['name'] ?? bot?['name'],
            'enabled': body['enabled'],
            'policy': body['policy'] ?? bot?['policy'] ?? _policy(),
          };
        }
        handler.resolve(Response(requestOptions: request, data: _status(bot)));
      }));
      final boundary = GlobalKey();
      await _pump(tester, auth,
          theme: dark ? ThemeMode.dark : ThemeMode.light,
          scale: scale,
          boundary: boundary);
      await tester.pumpAndSettle();
      expect(find.text('尚未创建机器人'), findsOneWidget);
      expect(find.text('合成创建者 的 AI'), findsOneWidget);
      final primary = find.byKey(const ValueKey('bot-save-profile'));
      expect(tester.getTopLeft(primary).dy,
          greaterThanOrEqualTo(tester.getBottomRight(find.byType(AppBar)).dy));
      expect(tester.getBottomRight(primary).dy, lessThanOrEqualTo(800));
      expect(tester.getSize(primary).height, greaterThanOrEqualTo(44));
      expect(
          tester
              .getSize(find.byKey(const ValueKey('bot-avatar-picker')))
              .height,
          greaterThanOrEqualTo(44));
      expect(
          tester.getSize(find.byKey(const ValueKey('bot-avatar-picker'))).width,
          greaterThanOrEqualTo(44));
      await _capture(tester, boundary, 'app-bot-create-$label');
      await _show(tester, find.byKey(const ValueKey('bot-save-profile')), 200);
      await tester.tap(find.byKey(const ValueKey('bot-save-profile')));
      await tester.pumpAndSettle();
      expect(writes.single,
          {'name': '大肥鱼', 'avatar': '', 'enabled': false, 'policy': _policy()});
      await _show(tester, find.text('启用机器人'), 200);
      await tester.tap(find.text('启用机器人'));
      await tester.pumpAndSettle();
      expect(writes.last['enabled'], true);
      await tester.scrollUntilVisible(find.text('机器人已启用'), -200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('机器人已启用'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('暂停机器人'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('暂停机器人'));
      await tester.pumpAndSettle();
      expect(writes.last, {'enabled': false});
      await tester.scrollUntilVisible(find.text('机器人已暂停'), -200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('机器人已暂停'), findsOneWidget);
      await _capture(tester, boundary, 'app-bot-managed-$label');
      await _expand(tester, 'bot-permissions-toggle');
      await _show(tester, find.text('自动文字评论'), 200);
      expect(
          tester
              .widget<Semantics>(
                  find.byKey(const ValueKey('bot-policy-reply_enabled')))
              .properties
              .toggled,
          false);
      await _show(
          tester, find.byKey(const ValueKey('bot-permissions-toggle')), -180);
      await _capture(tester, boundary, 'app-bot-permissions-$label');
      await _show(tester, find.text('自动评论服务：暂未开放'), 250);
      expect(find.text('自动评论服务：暂未开放'), findsOneWidget);
      expect(find.text('专用评论授权：尚未授权'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _expand(tester, 'bot-privacy-toggle');
      await _show(tester, find.textContaining('群聊仅保留短期上下文，不写长期记忆'), 250);
      expect(find.textContaining('群聊仅保留短期上下文，不写长期记忆'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'app-bot-$label');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('读取失败可重试，切号后旧创建者响应不能覆盖新账号', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    int calls = 0;
    final old = Completer<void>();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      final call = ++calls;
      if (call == 1) {
        handler.reject(DioException(requestOptions: request));
        return;
      }
      if (call == 2) await old.future;
      handler.resolve(Response(requestOptions: request, data: {
        'bot': {
          'bot_user_id': call,
          'name': call == 2 ? '旧账号机器人' : '新账号机器人',
          'enabled': true
        },
        'auto_reply_server_enabled': false,
        'auto_reply_authorized': false,
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载机器人'), findsOneWidget);
    expect(find.textContaining('新建'), findsNothing);
    await _expand(tester, 'bot-technical-toggle');
    expect(find.textContaining('操作未完成，请重试'), findsOneWidget);
    await tester.tap(find.text('重新读取状态'));
    await tester.pump();
    expect(find.text('正在读取机器人状态…'), findsOneWidget);
    auth.switchAccount();
    await tester.pumpAndSettle();
    old.complete();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '新账号机器人');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final profile in [
    (ThemeMode.light, 1.0, 'light'),
    (ThemeMode.dark, 1.0, 'dark'),
    (ThemeMode.light, 1.3, 'large')
  ]) {
    final (mode, scale, label) = profile;
    testWidgets('真实壁纸毛玻璃开关与滚动 $label', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(() {
        auth.dispose();
        dio.close();
        appearance.dispose();
      });
      await appearance.setBackgroundImage('morenbeijing.jpeg',
          fillScreen: true);
      await appearance.setComponentOpacity(.72);
      await appearance.setFrostedGlass(true);
      dio.interceptors.add(InterceptorsWrapper(
          onRequest: (request, handler) => handler.resolve(Response(
              requestOptions: request,
              data: _status(
                  {'bot_user_id': 10, 'name': '大肥鱼', 'enabled': true})))));
      final boundary = GlobalKey();
      await _pump(tester, auth,
          theme: mode,
          scale: scale,
          boundary: boundary,
          appearance: appearance);
      await tester.pumpAndSettle();
      final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
      await tester
          .runAsync(() => precacheImage(wallpaper, boundary.currentContext!));
      await tester.pumpAndSettle();
      expect(find.byType(CustomBackgroundLayer), findsOneWidget);
      expect(find.byType(AppCardSurface), findsWidgets);
      expect(activeBackdropFilters(), findsWidgets);
      expect(
          _surfaceAlpha(tester, 'bot-management-surface'), closeTo(.72, .001));
      expect(_surfaceAlpha(tester, 'bot-appbar-surface'), closeTo(.72, .001));
      expect(
          await _appBarContrast(tester, boundary), greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'app-bot-$label-glass-top');
      await _expand(tester, 'bot-permissions-toggle');
      await _show(
          tester, find.byKey(const ValueKey('bot-management-surface')), -200);
      final before = tester
          .getTopLeft(find.byKey(const ValueKey('bot-management-surface')))
          .dy;
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('bot-management-surface')))
              .dy,
          lessThan(before - 100));
      expect(
          _surfaceAlpha(tester, 'bot-management-surface'), closeTo(.72, .001));
      expect(_surfaceAlpha(tester, 'bot-appbar-surface'), closeTo(.72, .001));
      expect(
          await _appBarContrast(tester, boundary), greaterThanOrEqualTo(4.5));
      await _capture(tester, boundary, 'app-bot-$label-glass-scroll');
      await appearance.setComponentOpacity(.55);
      await tester.pumpAndSettle();
      expect(
          _surfaceAlpha(tester, 'bot-management-surface'), closeTo(.55, .001));
      expect(_surfaceAlpha(tester, 'bot-appbar-surface'), closeTo(.55, .001));
      expect(
          await _appBarContrast(tester, boundary), greaterThanOrEqualTo(4.5));
      await _capture(tester, boundary, 'app-bot-$label-glass-low-opacity');
      await appearance.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(activeBackdropFilters(), findsNothing);
      expect(
          _surfaceAlpha(tester, 'bot-management-surface'), closeTo(.55, .001));
      expect(_surfaceAlpha(tester, 'bot-appbar-surface'), closeTo(.55, .001));
      await _capture(tester, boundary, 'app-bot-$label-blur-off');
      await appearance.setFrostedGlass(true);
      await appearance.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      expect(_surfaceAlpha(tester, 'bot-management-surface'), 1);
      expect(_surfaceAlpha(tester, 'bot-appbar-surface'), 1);
      await _capture(tester, boundary, 'app-bot-$label-clean');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('大字键盘下加载与保存禁用操作，失败保留名称并允许重试', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final read = Completer<void>(), save = Completer<void>();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.method == 'POST') {
        await save.future;
        handler.reject(DioException(requestOptions: request));
      } else {
        await read.future;
        handler.resolve(Response(requestOptions: request, data: _status(null)));
      }
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth, scale: 1.5, boundary: boundary);
    expect(find.text('正在读取机器人状态…'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-loading-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-name')), findsNothing);
    read.complete();
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-name')), 200);
    await tester.enterText(find.byKey(const ValueKey('bot-name')), '新名字');
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-save-profile')), 200);
    final createButton = find.byKey(const ValueKey('bot-save-profile'));
    expect(tester.getTopLeft(createButton).dy,
        greaterThanOrEqualTo(tester.getBottomRight(find.byType(AppBar)).dy));
    expect(tester.getBottomRight(createButton).dy, lessThanOrEqualTo(500));
    await _capture(tester, boundary, 'app-bot-keyboard-large');
    await tester.tap(createButton);
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .enabled,
        false);
    save.complete();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '新名字');
    await _show(tester, find.textContaining('操作未完成，请重试'), -200);
    expect(find.textContaining('操作未完成，请重试'), findsOneWidget);
    expect(find.text('重新读取状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('社区权限和言论规则可在App编辑保存，刷新保留未保存草稿', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    Map<String, dynamic> bot = {
      'bot_user_id': 10,
      'name': '大肥鱼',
      'enabled': false,
      'policy': _policy()
    };
    final writes = <Map>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') {
        writes.add(Map.from(request.data as Map));
        bot = {...bot, ...Map<String, dynamic>.from(request.data as Map)};
      }
      handler.resolve(Response(requestOptions: request, data: _status(bot)));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-name')), 180);
    await tester.enterText(find.byKey(const ValueKey('bot-name')), '校园小鱼');
    await tester.tap(find.byTooltip('重新读取机器人状态'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '校园小鱼');
    await _expand(tester, 'bot-permissions-toggle');
    await _show(
        tester, find.byKey(const ValueKey('bot-policy-reply_enabled')), 220);
    await tester.tap(find.byKey(const ValueKey('bot-policy-reply_enabled')));
    await tester.pumpAndSettle();
    await _show(
        tester, find.byKey(const ValueKey('bot-policy-sticker_enabled')), 220);
    await tester.tap(find.byKey(const ValueKey('bot-policy-sticker_enabled')));
    await tester.pumpAndSettle();
    await _show(
        tester, find.byKey(const ValueKey('bot-section-course_study')), 220);
    await tester.tap(find.byKey(const ValueKey('bot-section-course_study')));
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-speech-toggle');
    await _show(tester, find.byKey(const ValueKey('bot-blocked-terms')), 200);
    await tester.enterText(
        find.byKey(const ValueKey('bot-blocked-terms')), '住址\n联系方式，住址');
    await _show(tester, find.byKey(const ValueKey('bot-interval')), 200);
    await tester.enterText(find.byKey(const ValueKey('bot-interval')), '90');
    await _show(tester, find.byKey(const ValueKey('bot-save-policy')), 200);
    await tester.tap(find.byKey(const ValueKey('bot-save-policy')));
    await tester.pumpAndSettle();
    final policy = writes.single['policy'] as Map;
    expect(writes.single['name'], '校园小鱼');
    expect(writes.single['enabled'], false);
    expect(policy['reply_enabled'], true);
    expect(policy['sticker_enabled'], true);
    expect(policy['allowed_post_types'], ['campus_life']);
    expect(policy['blocked_terms'], ['住址', '联系方式']);
    expect(policy['min_reply_interval_minutes'], 90);
    expect(policy['block_links'], true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧服务404不能新建或显示权限生效', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var writes = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes++;
      handler.reject(DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 404)));
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth, boundary: boundary);
    await tester.pumpAndSettle();
    expect(find.text('管理服务尚未就绪'), findsOneWidget);
    expect(find.text('暂未读到资料，已有机器人不会改变。'), findsOneWidget);
    expect(find.textContaining('检查服务版本与配置'), findsOneWidget);
    expect(find.textContaining('新建'), findsNothing);
    expect(find.text('尚未创建机器人'), findsNothing);
    expect(tester.getSize(find.widgetWithText(FilledButton, '重新读取状态')).height,
        greaterThanOrEqualTo(44));
    expect(
        tester.getBottomRight(find.widgetWithText(FilledButton, '重新读取状态')).dy,
        lessThanOrEqualTo(800));
    await _capture(tester, boundary, 'app-bot-server-upgrade');
    await _expand(tester, 'bot-technical-toggle', delta: -100);
    expect(find.textContaining('机器人管理接口不可用（HTTP 404）'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-save-profile')), findsNothing);
    expect(find.byKey(const ValueKey('bot-permissions-surface')), findsNothing);
    expect(writes, 0);
    await _capture(tester, boundary, 'app-bot-server-upgrade-details');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧基础服务明确降级，不发送未经支持的权限和头像', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    Map? write;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') write = Map.from(request.data as Map);
      handler.resolve(Response(requestOptions: request, data: {
        'bot': {'bot_user_id': 10, 'name': '旧机器人', 'enabled': true},
        'auto_reply_server_enabled': false,
        'auto_reply_authorized': false,
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-avatar-picker')), findsNothing);
    expect(find.byKey(const ValueKey('bot-permissions-surface')), findsNothing);
    await _show(tester, find.textContaining('仅支持基础资料'), 200);
    expect(find.textContaining('仅支持基础资料'), findsOneWidget);
    await _show(tester, find.byKey(const ValueKey('bot-save-profile')), -200);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('bot-save-profile')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .enabled,
        false);
    await tester.tap(find.byKey(const ValueKey('bot-save-profile')));
    await tester.pumpAndSettle();
    expect(write, isNull);
    await _show(tester, find.text('暂停机器人'), 150);
    await tester.tap(find.text('暂停机器人'));
    await tester.pumpAndSettle();
    expect(write, {'enabled': false});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('头像权限失败可恢复，取消和切号不会上传旧头像', (tester) async {
    final original = ImagePickerPlatform.instance;
    final picker = _Picker();
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = original);
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var uploads = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path == '/upload') uploads++;
      handler.resolve(Response(requestOptions: request, data: _status(null)));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    picker.denied = true;
    await _show(tester, find.byKey(const ValueKey('bot-avatar-picker')), 200);
    await tester.tap(find.byKey(const ValueKey('bot-avatar-picker')));
    await tester.pumpAndSettle();
    await _show(tester, find.textContaining('头像未能上传'), 250);
    expect(find.textContaining('头像未能上传'), findsOneWidget);
    picker.denied = false;
    await _show(tester, find.byKey(const ValueKey('bot-avatar-picker')), -200);
    await tester.tap(find.byKey(const ValueKey('bot-avatar-picker')));
    await tester.pumpAndSettle();
    expect(uploads, 0);
    picker.pending = Completer<XFile?>();
    await _show(tester, find.byKey(const ValueKey('bot-avatar-picker')), -200);
    await tester.tap(find.byKey(const ValueKey('bot-avatar-picker')));
    await tester.pump();
    auth.switchAccount();
    await tester.pumpAndSettle();
    picker.pending!.complete(XFile('assets/images/xiaoli.jpg'));
    await tester.pumpAndSettle();
    expect(uploads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('头像裁剪上传和保存归属当前会话，不修改创建者头像', (tester) async {
    final original = ImagePickerPlatform.instance;
    final picker = _Picker()..file = XFile('assets/images/xiaoli.jpg');
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = original);
    const crop = MethodChannel('plugins.hunghd.vn/image_cropper');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(crop, (call) async {
      expect(call.method, 'cropImage');
      expect((call.arguments as Map)['ratio_x'], 1.0);
      return File('assets/images/xiaoli.jpg').absolute.path;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(crop, null));
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final writes = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes.add(request);
      handler.resolve(Response(
          requestOptions: request,
          data: request.path == '/upload'
              ? {'url': '/uploads/bot-fixture.jpg'}
              : _status(null)));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-avatar-picker')), 200);
    await tester.tap(find.byKey(const ValueKey('bot-avatar-picker')));
    final uploadWait = Stopwatch()..start();
    while (writes.isEmpty && uploadWait.elapsed < const Duration(seconds: 5)) {
      // 平台回包需 pump，文件读取需真实事件循环，两者都推进到请求确实发出。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.path, '/upload');
    expect(writes.single.extra['expectedAuthUserId'], 7);
    expect(writes.single.extra['expectedAuthSessionEpoch'], 1);
    expect(writes.single.data, isA<FormData>());
    await _show(tester, find.byKey(const ValueKey('bot-save-profile')), 200);
    await tester.tap(find.byKey(const ValueKey('bot-save-profile')));
    await tester.pumpAndSettle();
    expect((writes.last.data as Map)['avatar'], '/uploads/bot-fixture.jpg');
    expect(writes.every((request) => request.path != '/user/avatar'), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final profile in [
    (ThemeMode.light, 1.0, 'light'),
    (ThemeMode.dark, 1.0, 'dark'),
    (ThemeMode.light, 1.3, 'large'),
    (ThemeMode.dark, 1.5, 'dark-large'),
  ]) {
    final (mode, scale, label) = profile;
    testWidgets('原生连接核对、敏感权限默认关闭、替换和撤销均可完成 $label', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      final writes = <RequestOptions>[];
      var revoked = false;
      final binding = {
        'binding_id': 'binding-fixture',
        'installation_name': '我的 AstrBot',
        'installation_id': 'local-fixture',
        'state': 'active',
        'epoch': 3,
        'scopes':
            'community:read actions:read_own community:propose community:bot_reply'
      };
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.method == 'POST') writes.add(request);
        if (request.path.endsWith('/revoke')) revoked = true;
        final data = request.path.endsWith('/lookup')
            ? {
                'consent_id': 'consent-fixture',
                'installation_name': '新 AstrBot',
                'installation_id': 'local-new-fixture',
                'user_code': 'ABCD-EFGH',
                'confirmation_nonce': 'fixture-nonce',
                'expires_at': '2026-11-02T12:00:00+08:00',
                'requested_scopes': [
                  'profile:read_minimal',
                  'community:read',
                  'actions:read_own',
                  'community:propose',
                  'community:bot_reply',
                  'community:bot_post',
                  'academic:grades:read',
                  'academic:erke:read',
                  'checkin:write'
                ],
                'existing_binding': binding,
              }
            : {
                'bindings': [
                  {...binding, 'state': revoked ? 'revoked' : 'active'}
                ],
                'personal_data_enabled': true
              };
        handler.resolve(Response(requestOptions: request, data: data));
      }));
      final boundary = GlobalKey();
      await _pump(tester, auth,
          home: const ManagedBotConnectionsScreen(),
          boundary: boundary,
          theme: mode,
          scale: scale);
      await tester.pumpAndSettle();
      await _openNativeRequest(tester);
      await tester.enterText(
          find.byKey(const ValueKey('bot-device-code')), 'ABCD-EFGH');
      await tester.pump();
      await tester.tap(find.text('查看授权请求'));
      await tester.pumpAndSettle();
      await _show(tester, find.text('授权给 新 AstrBot'), 160);
      await _capture(tester, boundary, 'app-bot-native-request-$label');
      for (final scope in [
        'community:propose',
        'community:bot_reply',
        'community:bot_post',
        'academic:grades:read',
        'academic:erke:read',
        'checkin:write'
      ]) {
        await _show(tester, find.byKey(ValueKey('bot-scope-$scope')), 200);
        expect(
            tester
                .widget<CheckboxListTile>(
                    find.byKey(ValueKey('bot-scope-$scope')))
                .value,
            false);
        if (scope == 'community:bot_reply') {
          await _capture(tester, boundary, 'app-bot-native-scopes-$label');
        }
      }
      for (final scope in [
        'community:propose',
        'community:bot_reply',
        'community:bot_post',
        'academic:grades:read',
        'academic:erke:read'
      ]) {
        await _show(tester, find.byKey(ValueKey('bot-scope-$scope')), -180);
        await tester.tap(find.byKey(ValueKey('bot-scope-$scope')));
        await tester.pumpAndSettle();
      }
      await _show(
          tester, find.byKey(const ValueKey('bot-consent-confirm')), 220);
      await tester.tap(find.byKey(const ValueKey('bot-consent-confirm')));
      await tester.pumpAndSettle();
      await _show(tester, find.text('授权此助手'), 180);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '授权此助手'))
              .onPressed,
          isNull);
      await _show(
          tester, find.byKey(const ValueKey('bot-consent-replace')), -180);
      await tester.tap(find.byKey(const ValueKey('bot-consent-replace')));
      await tester.pumpAndSettle();
      await _show(tester, find.text('授权此助手'), 180);
      await _capture(tester, boundary, 'app-bot-native-consent-$label');
      await tester.tap(find.text('授权此助手'));
      await tester.pumpAndSettle();
      final decision =
          writes.firstWhere((request) => request.path.endsWith('/decision'));
      expect(decision.data['confirmation_nonce'], 'fixture-nonce');
      expect(decision.data['replace_binding_id'], 'binding-fixture');
      expect(decision.data['expected_epoch'], 3);
      expect(decision.data['scopes'], contains('community:bot_reply'));
      expect(decision.data['scopes'], contains('community:bot_post'));
      expect(decision.data['scopes'],
          containsAll(['academic:grades:read', 'academic:erke:read']));
      expect(decision.data['scopes'], isNot(contains('checkin:write')));
      expect(decision.extra['expectedAuthUserId'], 7);
      await _show(tester, find.widgetWithText(TextButton, '断开连接'), -220);
      await tester.tap(find.widgetWithText(TextButton, '断开连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认断开'));
      await tester.pumpAndSettle();
      expect(revoked, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('原生连接旧账号的延迟核对响应不能在新账号授权', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final wait = Completer<void>();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.path.endsWith('/lookup')) {
        await wait.future;
        handler.resolve(Response(requestOptions: request, data: {
          'consent_id': 'old-consent',
          'installation_name': '旧账号设备',
          'installation_id': 'old',
          'user_code': 'ABCD',
          'confirmation_nonce': 'old-nonce',
          'requested_scopes': ['community:read'],
          'expires_at': 'later',
        }));
      } else {
        handler
            .resolve(Response(requestOptions: request, data: {'bindings': []}));
      }
    }));
    await _pump(tester, auth, home: const ManagedBotConnectionsScreen());
    await tester.pumpAndSettle();
    await _openNativeRequest(tester);
    await tester.enterText(
        find.byKey(const ValueKey('bot-device-code')), 'ABCD');
    await tester.pump();
    await tester.tap(find.text('查看授权请求'));
    await tester.pump();
    auth.switchAccount();
    await tester.pumpAndSettle();
    wait.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('旧账号设备'), findsNothing);
    expect(find.text('授权此助手'), findsNothing);
    await _openNativeRequest(tester);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-device-code')))
            .controller!
            .text,
        '');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原生连接读取失败后重试成功清除旧错误', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var calls = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (++calls == 1) {
        handler.reject(DioException(requestOptions: request));
      } else {
        handler
            .resolve(Response(requestOptions: request, data: {'bindings': []}));
      }
    }));
    await _pump(tester, auth, home: const ManagedBotConnectionsScreen());
    await tester.pumpAndSettle();
    expect(find.textContaining('连接操作未完成'), findsOneWidget);
    await _show(tester, find.text('重新读取连接'), 150);
    await tester.tap(find.text('重新读取连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接操作未完成'), findsNothing);
    expect(find.textContaining('暂无有效连接'), findsOneWidget);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('管理页直接进入原生连接，返回保留未保存资料', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.resolve(Response(
          requestOptions: request,
          data: request.path == '/connected-apps/bot'
              ? _status({'bot_user_id': 10, 'name': '大肥鱼', 'enabled': false})
              : {'bindings': []}));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-name')), 200);
    await tester.enterText(find.byKey(const ValueKey('bot-name')), '未保存的名字');
    final connectionButton =
        find.widgetWithText(OutlinedButton, '管理 AstrBot 连接与授权');
    await _show(tester, connectionButton, 250);
    await tester.ensureVisible(connectionButton);
    await tester.pumpAndSettle();
    await tester.tap(connectionButton);
    await tester.pumpAndSettle();
    expect(find.text('AstrBot 连接与授权'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    final title = tester.element(find.text('AstrBot 连接与授权'));
    expect(DefaultTextStyle.of(title).style.fontFamily, 'NotoSansCJKsc');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-name')), -250);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '未保存的名字');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('加载和网络失败保持未知状态，成功空响应后才允许创建', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final first = Completer<void>();
    var calls = 0;
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      if (++calls == 1) {
        await first.future;
        handler.reject(DioException(requestOptions: request));
      } else {
        handler.resolve(Response(requestOptions: request, data: _status(null)));
      }
    }));
    await _pump(tester, auth);
    expect(find.text('正在读取机器人状态…'), findsOneWidget);
    expect(find.textContaining('新建'), findsNothing);
    expect(find.byKey(const ValueKey('bot-name')), findsNothing);
    first.complete();
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载机器人'), findsOneWidget);
    expect(find.textContaining('尚未创建'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '重新读取状态'));
    await tester.pumpAndSettle();
    expect(find.text('尚未创建机器人'), findsOneWidget);
    expect(find.text('创建机器人'), findsOneWidget);
    expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('bot-save-profile')))
            .dy,
        lessThanOrEqualTo(800));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('管理接口404仍可核对和撤销连接，返回不误判机器人不存在', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path == '/connected-apps/bot') {
        handler.reject(DioException(
            requestOptions: request,
            response: Response(requestOptions: request, statusCode: 404)));
      } else {
        handler
            .resolve(Response(requestOptions: request, data: {'bindings': []}));
      }
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('自动评论服务：尚未核验'), findsOneWidget);
    expect(find.text('专用评论授权：尚未核验'), findsOneWidget);
    await _show(tester, find.text('管理 AstrBot 连接与授权'), 180);
    expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, '管理 AstrBot 连接与授权'))
            .height,
        greaterThanOrEqualTo(44));
    await tester.tap(find.text('管理 AstrBot 连接与授权'));
    await tester.pumpAndSettle();
    expect(find.text('AstrBot 连接与授权'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('管理服务尚未就绪'), findsOneWidget);
    expect(find.textContaining('新建'), findsNothing);
    expect(find.textContaining('尚未创建'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('刷新失败保留已有身份和草稿，旧授权不冒充当前核验且仍可暂停', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final refresh = Completer<void>();
    var reads = 0;
    var enabled = true;
    final writes = <Map>[];
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.method == 'POST') {
        writes.add(Map.from(request.data as Map));
        enabled = false;
      }
      if (request.method == 'GET' && ++reads == 2) {
        await refresh.future;
        handler.reject(DioException(requestOptions: request));
        return;
      }
      handler.resolve(Response(requestOptions: request, data: {
        ..._status({'bot_user_id': 10, 'name': '已有的小鱼', 'enabled': enabled}),
        'auto_reply_server_enabled': true,
        'auto_reply_authorized': true,
      }));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == '已有的小鱼'),
        findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('bot-name')), '未保存的昵称');
    await tester.tap(find.byTooltip('重新读取机器人状态'));
    await tester.pump();
    expect(find.text('正在更新，以下为上次确认的资料'), findsOneWidget);
    await _show(tester, find.text('自动评论服务：正在核验'), 150);
    refresh.complete();
    await tester.pumpAndSettle();
    expect(find.text('自动评论服务：尚未核验'), findsOneWidget);
    expect(find.text('专用评论授权：尚未核验'), findsOneWidget);
    await _show(tester, find.byKey(const ValueKey('bot-name')), -250);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '未保存的昵称');
    expect(find.text('状态未更新，以下为上次确认的资料'), findsOneWidget);
    await _show(tester, find.text('暂停机器人'), 150);
    await tester.tap(find.text('暂停机器人'));
    await tester.pumpAndSettle();
    expect(writes.single, {'enabled': false});
    await _show(tester, find.byKey(const ValueKey('bot-name')), -250);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '未保存的昵称');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('隐私和权限开合有语义且保留全部草稿与当前状态', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var writes = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes++;
      handler.resolve(Response(
          requestOptions: request,
          data: _status({'bot_user_id': 10, 'name': '小鱼', 'enabled': true})));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bot-name')), '保留此草稿');
    await _expand(tester, 'bot-permissions-toggle');
    await _show(
        tester, find.byKey(const ValueKey('bot-policy-reply_enabled')), 150);
    await tester.tap(find.byKey(const ValueKey('bot-policy-reply_enabled')));
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-permissions-toggle', delta: -180);
    final privacy = find.byKey(const ValueKey('bot-privacy-toggle'));
    await _show(tester, privacy, 250);
    expect(tester.getSize(privacy).height, greaterThanOrEqualTo(44));
    Semantics disclosureSemantics() => tester
        .widgetList<Semantics>(
            find.ancestor(of: privacy, matching: find.byType(Semantics)))
        .firstWhere((widget) => widget.properties.expanded != null);
    expect(disclosureSemantics().properties.expanded, false);
    expect(find.textContaining('群聊仅保留短期上下文，不写长期记忆'), findsNothing);
    await tester.tap(privacy);
    await tester.pumpAndSettle();
    expect(disclosureSemantics().properties.expanded, true);
    await _show(tester, find.textContaining('群聊仅保留短期上下文，不写长期记忆'), 150);
    expect(find.textContaining('群聊仅保留短期上下文，不写长期记忆'), findsOneWidget);
    await _expand(tester, 'bot-privacy-toggle', delta: -200);
    await _expand(tester, 'bot-permissions-toggle', delta: -250);
    await _show(
        tester, find.byKey(const ValueKey('bot-policy-reply_enabled')), 150);
    expect(
        tester
            .widget<Semantics>(
                find.byKey(const ValueKey('bot-policy-reply_enabled')))
            .properties
            .toggled,
        true);
    await _show(tester, find.byKey(const ValueKey('bot-name')), -250);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-name')))
            .controller!
            .text,
        '保留此草稿');
    expect(find.text('机器人已启用'), findsOneWidget);
    expect(writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('资源404显示资料不可用，不误判接口未开放或要求重新创建', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var writes = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes++;
      handler.reject(DioException(
          requestOptions: request,
          response: Response(
              requestOptions: request,
              statusCode: 404,
              data: {'code': 'resource_unavailable'})));
    }));
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('机器人资料暂时不可用'), findsOneWidget);
    expect(find.textContaining('新建'), findsNothing);
    expect(find.textContaining('尚未创建'), findsNothing);
    expect(find.textContaining('暂未开放此功能'), findsNothing);
    await _expand(tester, 'bot-technical-toggle');
    expect(find.text('已有机器人资料暂时不可用，请重试或联系维护者核对。'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新读取状态'), findsOneWidget);
    expect(writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final profile in [
    (ThemeMode.light, 1.0, 'light'),
    (ThemeMode.dark, 1.0, 'dark'),
    (ThemeMode.dark, 1.5, 'dark-large-long-owner')
  ]) {
    final (mode, scale, label) = profile;
    testWidgets('已有机器人首屏身份与主动作可达 $label', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        handler.resolve(Response(
            requestOptions: request,
            data: _status({
              'bot_user_id': 10,
              'name': scale > 1 ? '校园大肥鱼校园大肥鱼校园大肥鱼校园大肥鱼号机器人' : '大肥鱼',
              'enabled': true,
              'owner': {
                'id': 7,
                'nickname': scale > 1 ? '这是拥有很长公开昵称的校园机器人创建者同学同学同学' : '合成创建者'
              },
            })));
      }));
      final boundary = GlobalKey();
      await _pump(tester, auth, theme: mode, scale: scale, boundary: boundary);
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('bot-save-profile'));
      final pause = find.widgetWithText(OutlinedButton, '暂停机器人');
      expect(tester.getSize(save).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(pause).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(save).width, tester.getSize(pause).width);
      final avatar = find.byKey(const ValueKey('bot-avatar-picker'));
      expect(tester.getSize(avatar).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(avatar).width, greaterThanOrEqualTo(44));
      expect(tester.getTopLeft(avatar).dx, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(avatar).dx, lessThanOrEqualTo(360));
      expect(tester.getTopLeft(avatar).dy,
          greaterThanOrEqualTo(tester.getBottomRight(find.byType(AppBar)).dy));
      expect(tester.getBottomRight(avatar).dy, lessThanOrEqualTo(800));
      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
      expect(tester.getBottomRight(pause).dy, lessThanOrEqualTo(800));
      expect(tester.getSize(find.byTooltip('重新读取机器人状态')).height,
          greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'app-bot-existing-top-$label');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final profile in [
    (ThemeMode.light, 1.0, 'light', GoldenViewports.phone360x800),
    (ThemeMode.dark, 1.0, 'dark', GoldenViewports.phone360x800),
    (ThemeMode.light, 1.3, 'large', GoldenViewports.phone360x800),
    (ThemeMode.dark, 1.5, 'dark-large', GoldenViewports.phone360x800),
    (ThemeMode.light, 1.0, 'narrow', const Size(320, 800)),
  ]) {
    final (mode, scale, label, viewport) = profile;
    testWidgets('能力选择独立组合、总闸保留选择且布局可达 $label', (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      var writes = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.method == 'POST') writes++;
        handler.resolve(Response(
            requestOptions: request,
            data:
                _status({'bot_user_id': 10, 'name': '小鱼', 'enabled': false})));
      }));
      final boundary = GlobalKey();
      await _pump(tester, auth,
          theme: mode, scale: scale, viewport: viewport, boundary: boundary);
      await tester.pumpAndSettle();
      await _expand(tester, 'bot-permissions-toggle');
      final comment = find.byKey(const ValueKey('bot-policy-reply_enabled'));
      final sticker = find.byKey(const ValueKey('bot-policy-sticker_enabled'));
      await _show(tester, comment, 180);
      expect(tester.getSize(comment).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(sticker).height, greaterThanOrEqualTo(44));
      final stacked = scale > 1.2 || viewport.width < 340;
      if (stacked) {
        expect(tester.getTopLeft(sticker).dy,
            greaterThan(tester.getBottomRight(comment).dy));
      } else {
        expect(tester.getTopLeft(comment).dy, tester.getTopLeft(sticker).dy);
        expect(tester.getTopLeft(sticker).dx,
            greaterThan(tester.getTopLeft(comment).dx));
      }
      bool chosen(Finder finder) =>
          tester.widget<Semantics>(finder).properties.toggled!;
      await tester.tap(comment);
      await tester.pumpAndSettle();
      expect(chosen(comment), true);
      expect(chosen(sticker), false);
      await _show(tester, sticker, 180);
      await tester.tap(sticker);
      await tester.pumpAndSettle();
      expect(chosen(comment), true);
      expect(chosen(sticker), true);
      await _show(tester, comment, -180);
      await tester.tap(comment);
      await tester.pumpAndSettle();
      expect(chosen(comment), false);
      expect(chosen(sticker), true);
      await tester.tap(comment);
      await tester.pumpAndSettle();
      await _show(
          tester, find.byKey(const ValueKey('bot-permissions-toggle')), -180);
      await _capture(tester, boundary, 'permissions-selected-dirty-$label');
      final master =
          find.byKey(const ValueKey('bot-policy-public_read_enabled'));
      await _show(tester, master, 160);
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(comment).properties.enabled, false);
      expect(tester.widget<Semantics>(sticker).properties.enabled, false);
      expect(chosen(comment), true);
      expect(chosen(sticker), true);
      await _show(
          tester, find.byKey(const ValueKey('bot-permissions-toggle')), -180);
      expect(find.textContaining('浏览已关，发言暂停'), findsOneWidget);
      await _capture(tester, boundary, 'permissions-master-off-$label');
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(comment).properties.enabled, true);
      expect(chosen(comment), true);
      expect(chosen(sticker), true);
      await _show(
          tester, find.byKey(const ValueKey('bot-section-campus_life')), 200);
      expect(
          tester
              .widget<FilterChip>(
                  find.byKey(const ValueKey('bot-section-campus_life')))
              .selected,
          true);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('bot-section-campus_life')))
              .height,
          greaterThanOrEqualTo(44));
      expect(writes, 0);
      expect(tester.takeException(), isNull);
      if (label == 'light' || label == 'dark') {
        await _expand(tester, 'bot-speech-toggle');
        await _show(
            tester, find.byKey(const ValueKey('bot-speech-toggle')), -120);
        await _capture(tester, boundary, 'permissions-rhythm-$label');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('节奏快捷只填草稿、自定义跨折叠保留，显式保存才写入', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final writes = <Map>[];
    Map<String, dynamic> bot = {
      'bot_user_id': 10,
      'name': '小鱼',
      'enabled': false,
      'policy': _policy()
    };
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') {
        writes.add(Map.from(request.data as Map));
        bot = {...bot, ...Map<String, dynamic>.from(request.data as Map)};
      }
      handler.resolve(Response(requestOptions: request, data: _status(bot)));
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth,
        theme: ThemeMode.dark, scale: 1.5, boundary: boundary);
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-speech-toggle');
    await _show(tester, find.byKey(const ValueKey('bot-daily-limit')), 180);
    await tester.tap(find.byKey(const ValueKey('bot-daily-limit')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('1 条'), -100,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('1 条').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButton<int>>(
                find.byKey(const ValueKey('bot-daily-limit')))
            .value,
        1);
    await _show(
        tester, find.byKey(const ValueKey('bot-interval-preset-60')), 180);
    await tester.tap(find.byKey(const ValueKey('bot-interval-preset-60')));
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-interval')), 180);
    final interval = find.descendant(
        of: find.byKey(const ValueKey('bot-interval')),
        matching: find.byType(TextField));
    expect(tester.widget<TextField>(interval).controller!.text, '60');
    await tester.enterText(find.byKey(const ValueKey('bot-interval')), '90');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('bot-interval-preset-60')))
            .selected,
        false);
    await _expand(tester, 'bot-speech-toggle', delta: -250);
    await _expand(tester, 'bot-speech-toggle', delta: -100);
    await _show(tester, find.byKey(const ValueKey('bot-interval')), 180);
    expect(tester.widget<TextField>(interval).controller!.text, '90');
    await _show(tester, find.byKey(const ValueKey('bot-speech-toggle')), -200);
    await _capture(tester, boundary, 'permissions-rhythm-dark-large-dirty');
    expect(writes, isEmpty);
    await _show(tester, find.byKey(const ValueKey('bot-blocked-terms')), 200);
    await tester.enterText(
        find.byKey(const ValueKey('bot-blocked-terms')), '住址');
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const ValueKey('bot-save-policy')), 200);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bot-save-policy'))).dy,
        greaterThanOrEqualTo(tester.getBottomRight(find.byType(AppBar)).dy));
    expect(
        tester.getBottomRight(find.byKey(const ValueKey('bot-save-policy'))).dy,
        lessThanOrEqualTo(500));
    await _capture(tester, boundary, 'permissions-rules-keyboard');
    await tester.tap(find.byKey(const ValueKey('bot-save-policy')));
    await tester.pumpAndSettle();
    expect(writes.length, 1);
    final policy = writes.single['policy'] as Map;
    expect(policy, {
      ..._policy(),
      'daily_reply_limit': 1,
      'min_reply_interval_minutes': 90,
      'blocked_terms': ['住址']
    });
    expect(writes.single['enabled'], false);
    expect(writes.single.keys.toSet(), {'name', 'enabled', 'avatar', 'policy'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('失效范围计数不越界，明确移除后才能保存但暂停不受阻', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final writes = <Map>[];
    Map<String, dynamic> bot = {
      'bot_user_id': 10,
      'name': '小鱼',
      'enabled': true,
      'policy': {
        ..._policy(),
        'allowed_post_types': ['campus_life', 'retired_section']
      }
    };
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') {
        writes.add(Map.from(request.data as Map));
        bot = {...bot, ...Map<String, dynamic>.from(request.data as Map)};
      }
      handler.resolve(Response(requestOptions: request, data: _status(bot)));
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth, boundary: boundary);
    await tester.pumpAndSettle();
    expect(find.text('请先在社区权限中处理不可用板块，再保存或启用。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('bot-save-profile')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '暂停机器人'))
            .onPressed,
        isNotNull);
    await _expand(tester, 'bot-permissions-toggle');
    await _show(tester, find.byKey(const ValueKey('bot-section-count')), 200);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bot-section-count')))
            .data,
        '已选 1 / 2');
    await _show(tester,
        find.byKey(const ValueKey('bot-remove-unavailable-sections')), 180);
    await _capture(tester, boundary, 'permissions-unavailable-selection');
    await tester
        .tap(find.byKey(const ValueKey('bot-remove-unavailable-sections')));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.byKey(const ValueKey('bot-remove-unavailable-sections')),
        findsNothing);
    await _show(tester, find.byKey(const ValueKey('bot-save-policy')), 180);
    await tester.tap(find.byKey(const ValueKey('bot-save-policy')));
    await tester.pumpAndSettle();
    expect(writes.single['policy']['allowed_post_types'], ['campus_life']);
    expect(writes.single['enabled'], true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无可选板块和未选范围明确不可参与，不硬加任何板块', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    var empty = true, writes = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') writes++;
      handler.resolve(Response(requestOptions: request, data: {
        ..._status({
          'bot_user_id': auth.id + 10,
          'name': '小鱼',
          'enabled': false,
          'policy': {..._policy(), 'allowed_post_types': <String>[]}
        }),
        if (empty) 'sections': <Map>[],
      }));
    }));
    final boundary = GlobalKey();
    await _pump(tester, auth, boundary: boundary);
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-permissions-toggle');
    await _show(tester, find.byKey(const ValueKey('bot-section-count')), 180);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bot-section-count')))
            .data,
        '已选 0 / 0');
    expect(find.byType(FilterChip), findsNothing);
    expect(find.text('暂无可选公开板块，机器人不能浏览或发言。'), findsOneWidget);
    await _capture(tester, boundary, 'permissions-empty-sections');
    empty = false;
    auth.switchAccount();
    await tester.pumpAndSettle();
    await _expand(tester, 'bot-permissions-toggle');
    await _show(tester, find.byKey(const ValueKey('bot-section-count')), 180);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bot-section-count')))
            .data,
        '已选 0 / 2');
    expect(find.textContaining('未选板块，无法参与'), findsOneWidget);
    expect(find.text('未选择板块，机器人不会浏览或发言。'), findsOneWidget);
    await _capture(tester, boundary, 'permissions-no-selection');
    await tester.tap(find.byKey(const ValueKey('bot-section-campus_life')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilterChip>(
                find.byKey(const ValueKey('bot-section-campus_life')))
            .selected,
        true);
    expect(
        tester
            .widget<FilterChip>(
                find.byKey(const ValueKey('bot-section-course_study')))
            .selected,
        false);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bot-section-count')))
            .data,
        '已选 1 / 2');
    expect(writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
