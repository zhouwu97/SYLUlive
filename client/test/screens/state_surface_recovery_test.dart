import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/admin_canteen_operations_screen.dart';
import 'package:shenliyuan/screens/admin_water_sections_screen.dart';
import 'package:shenliyuan/screens/competition/competition_catalog_admin_screen.dart';
import 'package:shenliyuan/screens/poll/my_polls_screen.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/widgets/state_placeholder.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final page in ['poll', 'catalog']) {
    for (final dark in [false, true]) {
      testWidgets('$page 失败可重试、空态可读且大字号不溢出 dark=$dark',
          (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        var fail = true;
        var requests = 0;
        final dio = Dio();
        dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          requests++;
          if (fail) {
            h.reject(DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
              message: 'fixture offline',
            ));
          } else {
            h.resolve(Response(
              requestOptions: o,
              statusCode: 200,
              data: {'items': [], 'page': 1, 'limit': 20, 'total': 0},
            ));
          }
        }));
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appearance),
            ChangeNotifierProvider(create: (_) => PollProvider(PollService(dio))),
          ],
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: const TextScaler.linear(1.3),
            home: page == 'poll'
                ? const MyPollsScreen()
                : CompetitionCatalogAdminScreen(dio: dio),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(StatePlaceholder), findsOneWidget);
        expect(find.text('重新加载'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final previous = requests;
        fail = false;
        await tester.tap(find.text('重新加载'));
        await tester.pumpAndSettle();
        expect(requests, greaterThan(previous));
        expect(find.text(page == 'poll' ? '还没有发起投票' : '暂无目录包'), findsOneWidget);
        if (page == 'poll') {
          await tester.tap(find.text('我参与的'));
          await tester.pumpAndSettle();
          expect(find.text('还没有参与投票'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('版块管理空列表给出提示并可重新加载', (tester) async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      requests++;
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {'sections': []}));
    }));
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => WaterSectionProvider(dio),
      child: const GoldenTestApp(home: AdminWaterSectionsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('暂无可管理版块'), findsOneWidget);
    final before = requests;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(requests, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('食堂运营首帧后加载，不在构建时通知上层 Provider', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      h.resolve(Response(requestOptions: o, statusCode: 200, data: <Object>[]));
    }));
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => CanteenProvider(dio),
      child: const GoldenTestApp(home: AdminCanteenOperationsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('食堂运营'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
