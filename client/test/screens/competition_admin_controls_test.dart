import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/competition/competition_admin_center_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  setUpAll(loadTestFonts);
  for (final config in [
    (false, 360, 1.0),
    (true, 360, 1.0),
    (false, 360, 1.3),
    (true, 360, 1.3),
    (false, 390, 1.3),
  ]) {
    testWidgets('管理按钮文字完整且对比度达标 $config', (tester) async {
      await setGoldenViewport(
          tester,
          config.$2 == 360
              ? GoldenViewports.phone360x800
              : GoldenViewports.phone390x844);
      AppPreferencesStore.setMockInitialValues({});
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      await appearance.setBackgroundImage('morenbeijing.jpeg');
      await appearance.setFrostedGlass(true);
      await appearance.setComponentOpacity(.3);
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options);
        final data = switch (options.path) {
          '/admin/competition-catalog/packages' => {
              'items': [
                {'id': 1, 'is_active': true, 'dataset_version': 'fixture'}
              ]
            },
          '/competitions/categories' => [],
          '/admin/competitions/events' => {
              'items': [],
              'total': 0,
              'total_pages': 1
            },
          _ => <String, Object>{},
        };
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data));
      }));
      final auth = AuthProvider(dio, loadStoredAuth: false);
      addTearDown(auth.dispose);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appearance),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: GoldenTestApp(
          themeMode: config.$1 ? ThemeMode.dark : ThemeMode.light,
          textScaler: TextScaler.linear(config.$3),
          home: const CompetitionAdminCenterScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      final rects = <Rect>[];
      for (final label in ['目录包', '当前赛事', '历史归并']) {
        final text = find.text(label).first;
        final finder = find
            .ancestor(
                of: text,
                matching: find.byWidgetPredicate(
                    (w) => w is FilledButton || w is OutlinedButton))
            .first;
        final button = tester.widget<ButtonStyleButton>(finder);
        final foreground = button.style!.foregroundColor!.resolve({})!;
        final background = button.style!.backgroundColor!.resolve({})!;
        expect(background.a, 1);
        expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
        expect(tester.getSize(text).height, lessThan(config.$3 * 13 * 2),
            reason: '四字操作名必须在一行内完整显示');
        final rect = tester.getRect(finder);
        expect(rect.height, greaterThanOrEqualTo(44));
        rects.add(rect);
      }
      if (config.$2 == 360 && config.$3 == 1.3) {
        expect(rects.last.top, greaterThan(rects.first.top),
            reason: '窄屏大字号应整颗按钮换行');
      }
      final draft = find.text('草稿').last;
      await tester.ensureVisible(draft);
      final material = tester.widget<Material>(
          find.ancestor(of: draft, matching: find.byType(Material)).first);
      final text = tester.widget<Text>(draft);
      expect(material.color!.a, 1);
      expect(_contrast(text.style!.color!, material.color!),
          greaterThanOrEqualTo(4.5));
      await tester.tap(draft);
      await tester.pumpAndSettle();
      expect(
          requests
              .lastWhere((r) => r.path == '/admin/competitions/events')
              .queryParameters['status'],
          'draft');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
