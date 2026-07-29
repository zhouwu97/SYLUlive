import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_capability_profile_screen.dart';

class _CapabilityAdapter implements HttpClientAdapter {
  _CapabilityAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options, String body)
      handler;
  int accessPutCount = 0;
  final List<Map<String, dynamic>> accessBodies = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    await for (final chunk in requestStream ?? const Stream.empty()) {
      bytes.addAll(chunk);
    }
    final body = utf8.decode(bytes);
    if (options.method == 'PUT') {
      accessPutCount++;
      accessBodies.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
    }
    return handler(options, body);
  }
}

ResponseBody _jsonResponse(Object data, [int status = 200]) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

Map<String, dynamic> _profile({
  bool configured = true,
  int verified = 2,
  int selfReported = 1,
}) {
  return {
    'preference_configured': configured,
    'verified_award_count': verified,
    'self_reported_award_count': selfReported,
    'skill_summary': [
      {'skill': 'Python', 'verified_count': 1, 'self_reported_count': 1},
      {'skill': '算法', 'verified_count': 0, 'self_reported_count': 1},
    ],
    'role_summary': [
      {'role': 'developer', 'verified_count': 1, 'self_reported_count': 0},
    ],
    'direction_tags': ['程序设计', '数据分析'],
    'preferred_roles': ['developer', 'modeler'],
    'weekly_hours': 7,
    'accept_long_term_training': true,
  };
}

Dio _dio(_CapabilityAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Widget _app(Dio dio, {Object accountKey = 1, double textScale = 1}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: CompetitionCapabilityProfileScreen(
        dio: dio,
        accountKey: accountKey,
      ),
    ),
  );
}

_CapabilityAdapter _loadedAdapter({bool access = false}) {
  return _CapabilityAdapter((options, body) {
    if (options.path.endsWith('/ai-access')) {
      if (options.method == 'PUT') {
        final enabled =
            (Map<String, dynamic>.from(jsonDecode(body) as Map))['enabled'] ==
                true;
        return _jsonResponse({
          'enabled': enabled,
          'enabled_at': enabled ? '2026-07-23T00:00:00Z' : null,
        });
      }
      return _jsonResponse({'enabled': access, 'enabled_at': null});
    }
    return _jsonResponse(_profile());
  });
}

Future<void> _pumpLoaded(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('展示核验与自报分栏及偏好摘要', (tester) async {
    final adapter = _loadedAdapter();
    await _pumpLoaded(tester, _app(_dio(adapter)));

    expect(find.text('我的能力画像'), findsOneWidget);
    expect(find.text('已核验经历'), findsOneWidget);
    expect(find.text('本人填写经历'), findsOneWidget);
    expect(find.text('Python'), findsOneWidget);
    expect(find.text('1项已核验 · 1项本人填写'), findsOneWidget);
    expect(find.text('开发'), findsAtLeastNWidgets(1));
    expect(find.text('程序设计、数据分析'), findsOneWidget);
    expect(find.text('7 小时'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('competition-capability-ai-access')),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('授权开关只提交独立布尔值并更新状态', (tester) async {
    final adapter = _loadedAdapter();
    await _pumpLoaded(tester, _app(_dio(adapter)));

    await tester.tap(find.byKey(const Key('competition-capability-ai-access')));
    await tester.pumpAndSettle();

    expect(adapter.accessPutCount, 1);
    expect(adapter.accessBodies.single, {'enabled': true});
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('competition-capability-ai-access')),
          )
          .value,
      isTrue,
    );
    expect(find.text('已允许 AI 使用能力画像'), findsOneWidget);
  });

  testWidgets('授权保存失败保留原状态', (tester) async {
    final adapter = _CapabilityAdapter((options, _) {
      if (options.path.endsWith('/ai-access')) {
        if (options.method == 'PUT') {
          return _jsonResponse({'error': '授权服务暂不可用'}, 500);
        }
        return _jsonResponse({'enabled': false, 'enabled_at': null});
      }
      return _jsonResponse(_profile());
    });
    await _pumpLoaded(tester, _app(_dio(adapter)));

    await tester.tap(find.byKey(const Key('competition-capability-ai-access')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('competition-capability-ai-access')),
          )
          .value,
      isFalse,
    );
    expect(find.text('授权服务暂不可用'), findsOneWidget);
  });

  testWidgets('无经历和无偏好时显示稳定空状态', (tester) async {
    final adapter = _CapabilityAdapter((options, _) {
      if (options.path.endsWith('/ai-access')) {
        return _jsonResponse({'enabled': false, 'enabled_at': null});
      }
      return _jsonResponse({
        ..._profile(configured: false, verified: 0, selfReported: 0),
        'skill_summary': [],
        'role_summary': [],
        'direction_tags': [],
        'preferred_roles': [],
        'weekly_hours': 0,
        'accept_long_term_training': false,
      });
    });
    await _pumpLoaded(tester, _app(_dio(adapter)));

    expect(find.text('还不能生成能力画像'), findsOneWidget);
    expect(find.text('设置竞赛目标'), findsOneWidget);
    expect(find.text('添加竞赛经历'), findsOneWidget);
    expect(find.text('暂无可汇总的竞赛技能'), findsNothing);
  });

  testWidgets('账号变化时不保留上一用户画像', (tester) async {
    final firstDio = _dio(_loadedAdapter());
    await _pumpLoaded(tester, _app(firstDio, accountKey: 1));
    expect(find.text('Python'), findsOneWidget);

    final profileCompleter = Completer<ResponseBody>();
    final secondAdapter = _CapabilityAdapter((options, _) {
      if (options.path.endsWith('/ai-access')) {
        return _jsonResponse({'enabled': false, 'enabled_at': null});
      }
      return profileCompleter.future;
    });
    await tester.pumpWidget(_app(_dio(secondAdapter), accountKey: 2));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Python'), findsNothing);

    profileCompleter.complete(
      _jsonResponse({
        ..._profile(verified: 0, selfReported: 0),
        'skill_summary': [],
        'role_summary': [],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无可汇总的竞赛技能'), findsOneWidget);
  });

  testWidgets('授权接口失败不阻止画像内容展示', (tester) async {
    final adapter = _CapabilityAdapter((options, _) {
      if (options.path.endsWith('/ai-access')) {
        return _jsonResponse({'error': '授权服务暂不可用'}, 500);
      }
      return _jsonResponse(_profile());
    });

    await _pumpLoaded(tester, _app(_dio(adapter)));

    expect(find.text('Python'), findsOneWidget);
    expect(find.text('已核验经历'), findsOneWidget);
    expect(find.text('AI 授权状态读取失败'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('小屏大字体布局不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpLoaded(tester, _app(_dio(_loadedAdapter()), textScale: 2));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
