import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/security_event.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_security_center_screen.dart';
import 'package:shenliyuan/utils/security_event_presentation.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  User current = User(
      id: 1,
      studentId: '',
      nickname: '测试管理员',
      role: 'admin',
      createdAt: DateTime(2026));
  @override
  User get user => current;
  void switchAccount() {
    current = User(
        id: 2,
        studentId: '',
        nickname: '另一个管理员',
        role: 'admin',
        createdAt: DateTime(2026));
    notifyListeners();
  }
}

Map<String, dynamic> _event(int id,
        {String ip = '1.2.3.4',
        String status = 'available',
        String region = '中国 · 辽宁省 · 沈阳市',
        String regionStatus = 'resolved',
        bool trusted = true}) =>
    {
      'id': id,
      'event_type': 'login_bruteforce',
      'severity': 'high',
      'status': 'active',
      'route': '/api/login',
      'method': 'POST',
      'source_fingerprint': 'abcd…1234',
      'source_ip': ip,
      'source_ip_status': status,
      'source_region': region,
      'source_region_status': regionStatus,
      'source_attribution_valid': trusted,
      'target_masked': '测试目标$id',
      'attempt_count': 20,
      'actionable': true,
      'first_seen_at': '2026-10-25T01:00:00Z',
      'last_seen_at': '2026-10-25T01:10:00Z',
    };

class _Api {
  final dio = Dio();
  late final auth = _Auth(dio);
  Future<dynamic> Function(RequestOptions)? events;
  bool denied = false;
  _Api() {
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (denied) {
        handler.reject(DioException(
            requestOptions: options,
            response: Response(
                requestOptions: options,
                statusCode: 403,
                data: {'error': '没有安全中心权限'})));
        return;
      }
      try {
        final data = options.path.endsWith('/overview')
            ? {
                'range': '24h',
                'actionable_high_count': 1,
                'protection': {
                  'security_ip_location': 'ready',
                  'security_ip_location_note': 'IPv4/IPv6 离线查询'
                }
              }
            : await events?.call(options) ??
                {
                  'items': [_event(1)],
                  'total': 1,
                  'limit': 50
                };
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data));
      } catch (_) {
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.connectionError));
      }
    }));
  }
}

Future<GlobalKey> _pump(WidgetTester tester, _Api api,
    {ThemeMode mode = ThemeMode.light,
    double textScale = 1,
    ThemeProvider? appearance}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final capture = GlobalKey();
  await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: api.auth),
        ChangeNotifierProvider(
            create: (_) => appearance ?? ThemeProvider(loadOnStart: false)),
      ],
      child: RepaintBoundary(
          key: capture,
          child: GoldenTestApp(
              themeMode: mode,
              textScaler: TextScaler.linear(textScale),
              home: const AdminSecurityCenterScreen()))));
  return capture;
}

Future<void> _save(WidgetTester tester, GlobalKey capture, String name) async {
  final dir = Platform.environment['SECURITY_QA_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(png.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300,
      scrollable: find.byType(Scrollable).first, maxScrolls: 100);
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('安全中心顶栏随背景切换且保持文字可读 $mode', (tester) async {
      final appearance = ThemeProvider(loadOnStart: false);
      await appearance.setBackgroundImage('morenbeijing.jpeg');
      final api = _Api();
      await _pump(tester, api, mode: mode, appearance: appearance);
      await tester.pumpAndSettle();
      expect(find.byType(CustomBackgroundLayer), findsOneWidget);
      expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
          Colors.transparent);
      final scheme = Theme.of(tester.element(find.byType(AppBar))).colorScheme;
      expect(tester.widget<AppBar>(find.byType(AppBar)).foregroundColor,
          scheme.onSurface);
      await appearance.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
          scheme.surface);
      expect(tester.takeException(), isNull);
    });
  }

  test('旧接口与不可信来源不会把指纹当作 IP 或暴露伪造地址', () {
    final old =
        SecurityEvent.fromJson({'id': 1, 'source_fingerprint': 'abcd1234'});
    expect(securityEventHasSourceIP(old), false);
    expect(securityEventSourceIPLabel(old), contains('未记录 IP'));
    final untrusted = SecurityEvent.fromJson(_event(1, trusted: false));
    expect(securityEventSourceIPLabel(untrusted), '来源归因不可用');
    expect(securityEventSourceRegionLabel(untrusted), isNot(contains('沈阳')));
    final missing =
        SecurityEvent.fromJson(_event(1, regionStatus: 'database_unavailable'));
    expect(securityEventSourceRegionLabel(missing), '离线 IP 库未加载');
  });

  for (final profile in ['light', 'dark', 'large']) {
    testWidgets('预警 IP 与归属地在 $profile 列表和详情中显示且可复制', (tester) async {
      String? copiedIP;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedIP = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': copiedIP};
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final api = _Api();
      final capture = await _pump(tester, api,
          mode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          textScale: profile == 'large' ? 1.3 : 1);
      await tester.pumpAndSettle();
      final ip = find.text('预警 IP：1.2.3.4');
      await _visible(tester, ip);
      await tester.pumpAndSettle();
      expect(find.text('归属地：中国 · 辽宁省 · 沈阳市'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _save(tester, capture, 'security-$profile-list');
      await tester.tap(ip);
      await tester.pumpAndSettle();
      expect(find.text('大致归属地：中国 · 辽宁省 · 沈阳市'), findsOneWidget);
      final copy = find.text('复制 IP');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      final clipboard =
          await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain));
      expect(clipboard?.text, '1.2.3.4');
      await _save(tester, capture, 'security-$profile-detail');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('加载更多失败保留前页，重试后展示第 51 条预警', (tester) async {
    final api = _Api();
    var secondAttempts = 0;
    api.events = (options) async {
      if (options.queryParameters['page'] == 2) {
        if (secondAttempts++ == 0) throw StateError('offline');
        return {
          'items': [_event(51)],
          'total': 51,
          'limit': 50
        };
      }
      return {
        'items': List.generate(50, (i) => _event(i + 1)),
        'total': 51,
        'limit': 50
      };
    };
    await _pump(tester, api);
    await tester.pumpAndSettle();
    final more = find.text('加载更多');
    await _visible(tester, more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('更多预警加载失败'), findsOneWidget);
    expect(find.text('已加载 50 条，共 51 条'), findsOneWidget);
    final retry = find.text('重试加载更多');
    await _visible(tester, retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text('目标：测试目标51'), findsOneWidget);
    await _visible(tester, find.text('已加载 51 条，共 51 条'));
    expect(find.text('已加载 51 条，共 51 条'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('分页请求晚到不能覆盖新筛选，账号切换清理旧预警', (tester) async {
    final api = _Api();
    final stale = Completer<dynamic>();
    api.events = (options) async {
      if (options.queryParameters['page'] == 2) return stale.future;
      if (api.auth.user.id == 2) {
        return {
          'items': [_event(200, ip: '8.8.8.8')],
          'total': 1
        };
      }
      if (options.queryParameters['status'] == 'resolved') {
        return {
          'items': [_event(100)],
          'total': 1
        };
      }
      return {
        'items': List.generate(50, (i) => _event(i + 1)),
        'total': 51,
        'limit': 50
      };
    };
    await _pump(tester, api);
    await tester.pumpAndSettle();
    final more = find.text('加载更多');
    await _visible(tester, more);
    await tester.tap(more);
    await tester.pump();
    final filter = find.text('已处理').first;
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await _visible(tester, filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await _visible(tester, find.text('目标：测试目标100'));
    api.auth.switchAccount();
    await tester.pumpAndSettle();
    await _visible(tester, find.text('目标：测试目标200'));
    expect(find.text('目标：测试目标100'), findsNothing);
    expect(find.text('目标：测试目标200'), findsOneWidget);
    stale.complete({
      'items': [_event(51)],
      'total': 51
    });
    await tester.pumpAndSettle();
    expect(find.text('目标：测试目标51'), findsNothing);
    expect(find.text('目标：测试目标200'), findsOneWidget);
  });

  testWidgets('权限错误、重试与空状态显示清楚', (tester) async {
    final api = _Api()..denied = true;
    await _pump(tester, api);
    await tester.pumpAndSettle();
    await _visible(tester, find.text('没有安全中心权限'));
    expect(find.text('没有安全中心权限'), findsOneWidget);
    api.denied = false;
    api.events = (_) async => {'items': [], 'total': 0};
    final retry = find.text('重试');
    await _visible(tester, retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await _visible(tester, find.text('当前没有需要处置的安全事件'));
    expect(find.text('当前没有需要处置的安全事件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开详情后切换账号会移除旧 IP 与处置入口', (tester) async {
    final api = _Api();
    api.events = (_) async => {
          'items': [
            _event(api.auth.user.id,
                ip: api.auth.user.id == 1 ? '1.2.3.4' : '8.8.8.8')
          ],
          'total': 1
        };
    await _pump(tester, api);
    await tester.pumpAndSettle();
    final ip = find.text('预警 IP：1.2.3.4');
    await _visible(tester, ip);
    await tester.tap(ip);
    await tester.pumpAndSettle();
    expect(find.text('复制 IP'), findsOneWidget);
    api.auth.switchAccount();
    await tester.pumpAndSettle();
    expect(find.text('账号已切换，请重新打开预警'), findsOneWidget);
    expect(find.text('复制 IP'), findsNothing);
    expect(find.textContaining('预警 IP：1.2.3.4'), findsNothing);
    expect(find.text('标记已处理'), findsNothing);
  });
}
