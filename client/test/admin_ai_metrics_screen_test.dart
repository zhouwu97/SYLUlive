import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/admin_ai_metrics_screen.dart';

import 'helpers/golden_test_app.dart';
import 'helpers/golden_viewport.dart';
import 'helpers/load_test_fonts.dart';

class _MetricsAuth extends ChangeNotifier implements AuthProvider {
  _MetricsAuth(this.dio);

  @override
  final Dio dio;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _metrics(Object? cost) => {
      'days': 7,
      'requests': 34,
      'success_rate': 19 / 34,
      'input_output_tokens': 175588,
      'cost_micro_yuan': cost,
      'by_provider': [
        {'provider': 'openai-compatible', 'cost_micro_yuan': cost},
      ],
    };

Future<void> _mount(WidgetTester tester, Dio dio,
    {ThemeMode mode = ThemeMode.light, bool large = false}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final auth = _MetricsAuth(dio);
  addTearDown(auth.dispose);
  await tester.pumpWidget(GoldenTestApp(
    themeMode: mode,
    textScaler: large ? const TextScaler.linear(1.3) : TextScaler.noScaling,
    home: ChangeNotifierProvider<AuthProvider>.value(
      value: auth,
      child: const AdminAIMetricsScreen(),
    ),
  ));
}

Dio _respond(Object? data) => Dio()
  ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    expect(options.path, '/admin/ai/metrics');
    expect(options.queryParameters['days'], 7);
    handler.resolve(Response(requestOptions: options, data: data));
  }));

void main() {
  setUpAll(loadTestFonts);

  for (final large in [false, true]) {
    testWidgets(
        'USD price table excludes unpriced historical models, large=$large',
        (tester) async {
      final metrics = _metrics(804364)
        ..addAll({
          'cost_currency': 'USD',
          'cost_nano_usd': 3392160,
          'priced_requests': 7,
          'unpriced_requests': 27,
          'by_model': [
            {
              'name': 'gpt-5.4-mini',
              'cost_currency': 'USD',
              'cost_nano_usd': 0,
              'priced_requests': 0,
              'unpriced_requests': 11
            },
          ],
        });
      await _mount(tester, _respond(metrics), large: large);
      await tester.pumpAndSettle();
      expect(find.text('\$0.003392'), findsOneWidget);
      expect(find.textContaining('已定价 7 条 · 未定价 27 条'), findsOneWidget);
      expect(find.textContaining('美元（USD）'), findsOneWidget);
      await tester.ensureVisible(find.text('模型'));
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      expect(find.textContaining('预估成本 未定价'), findsOneWidget);
      expect(find.text('¥0.8044'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final profile in ['light', 'dark', 'large']) {
    testWidgets('cost uses yuan in totals and provider details: $profile',
        (tester) async {
      await _mount(tester, _respond(_metrics(804364)),
          mode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          large: profile == 'large');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('最近 7 天'), findsOneWidget);
      expect(find.text('预估成本'), findsOneWidget);
      expect(find.text('¥0.8044'), findsOneWidget);
      expect(find.textContaining('不代表上游实际扣费'), findsOneWidget);
      await tester.tap(find.text('Provider'));
      await tester.pumpAndSettle();
      expect(find.textContaining('预估成本 ¥0.8044'), findsOneWidget);
      expect(find.textContaining('μ¥'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final sample in <(Object?, String)>[
    (0, '¥0.0000'),
    (1, '¥0.000001'),
    ('804364', '¥0.8044'),
    (null, '—'),
    (-1, '—'),
  ]) {
    testWidgets('cost handles zero, tiny or unavailable value: ${sample.$1}',
        (tester) async {
      await _mount(tester, _respond(_metrics(sample.$1)));
      await tester.pumpAndSettle();
      expect(find.text(sample.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed request can be refreshed and zero metrics remain valid',
      (tester) async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        calls++;
        if (calls == 1) {
          handler.reject(DioException(requestOptions: options));
        } else {
          handler.resolve(Response(requestOptions: options, data: {
            'requests': 0,
            'cost_micro_yuan': 0,
            'by_provider': <Object>[],
          }));
        }
      }));
    await _mount(tester, dio);
    await tester.pumpAndSettle();
    expect(find.textContaining('读取 AI 指标失败'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新指标'));
    await tester.pumpAndSettle();
    expect(find.text('¥0.0000'), findsOneWidget);
    expect(find.textContaining('读取 AI 指标失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
