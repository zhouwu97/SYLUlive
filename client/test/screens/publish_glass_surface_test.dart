import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/poll/poll_composer_screen.dart';
import 'package:shenliyuan/widgets/app_input_surface.dart';
import 'package:shenliyuan/screens/publish/market_publish_form.dart';
import 'package:shenliyuan/screens/publish/water_post_composer.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import '../helpers/golden_viewport.dart';
import 'water_post_composer_ui_test.dart'
    show FakeAuthProvider, FakePostProvider;

void main() {
  for (final page in ['water', 'poll', 'market']) {
    for (final dark in [false, true]) {
      for (final clean in [false, true]) {
        testWidgets('$page 材质、背景、安全区和草稿 dark=$dark clean=$clean',
            (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          AppPreferencesStore.setMockInitialValues({});
          final appearance = ThemeProvider(loadOnStart: false);
          addTearDown(appearance.dispose);
          await appearance.setBackgroundImage('morenbeijing.jpeg');
          if (clean) await appearance.setCleanBackgroundMode();
          await appearance.setFrostedGlass(true);
          await tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: appearance),
              ChangeNotifierProvider<AuthProvider>(
                  create: (_) => FakeAuthProvider()),
              ChangeNotifierProvider<PostProvider>(
                  create: (_) => FakePostProvider()),
              ChangeNotifierProvider(create: (_) => WaterSectionProvider(null)),
              ChangeNotifierProvider(
                  create: (_) =>
                      PollProvider(PollService(Dio()))..syncSessionUser(10, 1)),
            ],
            child: MaterialApp(
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.3),
                  padding: const EdgeInsets.only(bottom: 24),
                  viewPadding: const EdgeInsets.only(bottom: 24),
                ),
                child: child!,
              ),
              home: switch (page) {
                'water' => const WaterPostComposer(),
                'poll' => const PollComposerScreen(),
                _ => const MarketPublishForm(defaultPostType: 'sell'),
              },
            ),
          ));
          await tester.pumpAndSettle();
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
          expect(scaffold.backgroundColor == Colors.transparent, !clean);
          final appBar = tester.widget<AppBar>(find.byType(AppBar));
          expect(appBar.systemOverlayStyle!.systemNavigationBarColor,
              Colors.transparent);
          expect(appBar.systemOverlayStyle!.systemNavigationBarContrastEnforced,
              false);
          expect(find.byType(CustomBackgroundLayer), findsOneWidget);

          final bottom = find.byKey(ValueKey('$page-publish-bottom-surface'));
          expect(
              find.descendant(
                  of: bottom, matching: find.byType(BackdropFilter)),
              findsNWidgets(2),
              reason: '底部栏与独立发布按钮各有一个底面，前景文字不参与透明合成');
          // 材质包住 SafeArea，手势区不会露出另一层不透明底色。
          expect(tester.getRect(bottom).bottom, closeTo(844, .1));
          final bottomSurface = tester.widget<AppCardSurface>(bottom);
          expect((bottomSurface.decoration! as BoxDecoration).borderRadius,
              BorderRadius.zero);

          if (page == 'market') {
            final body = tester.widget<DecoratedBox>(
                find.byKey(const ValueKey('market-publish-page-body')));
            expect(
                (body.decoration as BoxDecoration).color == Colors.transparent,
                !clean);
            expect(
                find.descendant(
                    of: find.byKey(
                        const ValueKey('market-publish-details-surface')),
                    matching: find.byType(BackdropFilter)),
                findsOneWidget);
          } else if (page == 'poll') {
            expect(find.byType(AppInputSurface), findsWidgets);
            for (final field
                in tester.widgetList<TextField>(find.byType(TextField))) {
              expect(field.decoration!.filled, false);
            }
          } else {
            expect(
                find.descendant(
                    of: find.byKey(const ValueKey('publish-section-surface')),
                    matching: find.byType(BackdropFilter)),
                findsOneWidget);
          }

          final input = page == 'poll'
              ? find.byType(TextField).first
              : find.byType(TextFormField).first;
          await tester.enterText(input, '保留发布草稿');
          await tester.pump();
          await appearance.setFrostedGlass(false);
          await tester.pumpAndSettle();
          expect(find.text('保留发布草稿'), findsOneWidget);
          expect(
              find.descendant(
                  of: bottom, matching: find.byType(BackdropFilter)),
              findsNothing);
          await appearance.setFrostedGlass(true);
          await tester.pumpAndSettle();
          expect(find.text('保留发布草稿'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
