import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/competition/competition_award_verification_admin_screen.dart';
import 'package:shenliyuan/screens/competition/competition_center_screen.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final page in ['detail', 'calendar', 'editor', 'import', 'verification']) {
    for (final dark in [false, true]) {
      testWidgets('竞赛深层 $page 保留背景、返回与材质开关 dark=$dark', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        final dio = Dio();
        dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          h.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
            message: 'fixture offline',
          ));
        }));
        final screen = switch (page) {
          'detail' => const CompetitionDetailScreen(eventId: 1),
          'calendar' => const CompetitionCalendarScreen(),
          'editor' => CompetitionCalendarItemEditorScreen(categories: [
              CompetitionCategory(id: 1, name: '科技竞赛', slug: 'science'),
            ]),
          'import' => const CompetitionShareImportScreen(),
          _ => CompetitionAwardVerificationDetailScreen(dio: dio, awardId: 1),
        };
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appearance),
            ChangeNotifierProvider<AuthProvider>(create: (_) => SurfaceFixtureAuth(dio)),
          ],
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: const TextScaler.linear(1.3),
            home: Builder(builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('打开详情'),
              ),
            )),
          ),
        ));
        await tester.tap(find.text('打开详情'));
        await tester.pumpAndSettle();
        expect(find.byType(CustomBackgroundLayer), findsOneWidget);
        final rect = tester.getRect(find.byType(Scaffold).last);
        expect(tester.takeException(), isNull);
        await appearance.setFrostedGlass(true);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(Scaffold).last), rect);
        await appearance.setCleanBackgroundMode();
        await tester.pumpAndSettle();
        expect(appearance.backgroundImage, 'morenbeijing.jpeg');
        expect(tester.takeException(), isNull);
        final backLabel = MaterialLocalizations.of(
                tester.element(find.byType(AppBar).last)).backButtonTooltip;
        await tester.tap(find.byTooltip(backLabel));
        await tester.pumpAndSettle();
        expect(find.text('打开详情'), findsOneWidget);
      });
    }
  }
}
