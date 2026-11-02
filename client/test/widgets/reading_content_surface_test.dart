import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final card in [false, true]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        for (final custom in [false, true]) {
          testWidgets(
              '内容有圆角底面且布局不变 card=$card dark=$dark scale=$scale custom=$custom',
              (tester) async {
            await setGoldenViewport(tester, GoldenViewports.phone390x844);
            AppPreferencesStore.setMockInitialValues({});
            final appearance = ThemeProvider(loadOnStart: false);
            addTearDown(appearance.dispose);
            await appearance.setBackgroundImage('morenbeijing.jpeg');
            await appearance.setComponentOpacity(.75);
            if (!custom) await appearance.setCleanBackgroundMode();
            const text = Text('只有一行的步骤说明也属于阅读内容');
            final content = card
                ? const Padding(padding: EdgeInsets.all(24), child: text)
                : text;
            Widget app(Widget child) => ChangeNotifierProvider.value(
                  value: appearance,
                  child: GoldenTestApp(
                    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                    textScaler: TextScaler.linear(scale),
                    home: Scaffold(
                      body: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Align(alignment: Alignment.topLeft, child: child),
                      ),
                    ),
                  ),
                );
            await tester.pumpWidget(app(content));
            await tester.pumpAndSettle();
            final before = tester.getRect(find.byType(Text).first);
            final contentBefore = tester.getRect(find.byWidget(content));
            await tester.pumpWidget(app(card
                ? AppContentSurface.card(child: content)
                : AppContentSurface.reading(child: content)));
            await tester.pumpAndSettle();
            for (final glass in [false, true, false]) {
              await appearance.setFrostedGlass(glass);
              await tester.pumpAndSettle();
              expect(tester.getRect(find.byType(Text).first), before);
              final surface = find.byType(AppCardSurface);
              expect(surface, findsOneWidget);
              expect(
                  tester.getRect(surface),
                  card
                      ? contentBefore
                      : Rect.fromLTRB(before.left - 8, before.top - 4,
                          before.right + 8, before.bottom + 4));
              final decoration = tester
                  .widget<AppCardSurface>(surface)
                  .decoration! as BoxDecoration;
              expect(decoration.borderRadius,
                  BorderRadius.circular(card ? AppRadius.lg : AppRadius.md));
              final paint = tester.widget<DecoratedBox>(find
                  .descendant(of: surface, matching: find.byType(DecoratedBox))
                  .first);
              expect((paint.decoration as BoxDecoration).color!.a,
                  closeTo(custom ? .75 : 0, .005));
              expect(activeBackdropFilters(),
                  custom && glass ? findsOneWidget : findsNothing);
              expect(tester.takeException(), isNull);
            }
          });
        }
      }
    }
  }

  testWidgets('已有内容卡片中的说明不重复叠加材质', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    await appearance.setBackgroundImage('morenbeijing.jpeg');
    await appearance.setFrostedGlass(true);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: appearance,
      child: const GoldenTestApp(
          home: Scaffold(
              body: AppCardMaterial(
        child: Padding(
            padding: EdgeInsets.all(24),
            child: AppContentSurface.reading(child: Text('保留原卡片底面'))),
      ))),
    ));
    await tester.pumpAndSettle();
    expect(activeBackdropFilters(), findsOneWidget);
    expect(
        tester
            .widget<AppCardSurface>(find.byType(AppCardSurface))
            .surfaceOpacity,
        0);
    expect(tester.takeException(), isNull);
  });
}
