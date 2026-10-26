import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/app_bottom_sheet.dart';
import '../helpers/golden_viewport.dart';

void main() {
  for (final dark in [false, true]) {
    for (final clean in [false, true]) {
      for (final glass in [false, true]) {
        testWidgets('系统弹层材质、手柄及返回值 dark=$dark clean=$clean glass=$glass',
            (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          AppPreferencesStore.setMockInitialValues({});
          final appearance = ThemeProvider(loadOnStart: false);
          addTearDown(appearance.dispose);
          await appearance.setBackgroundImage('morenbeijing.jpeg');
          if (clean) await appearance.setCleanBackgroundMode();
          await appearance.setFrostedGlass(glass);
          int? selected;
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: appearance,
            child: MaterialApp(
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              home: Scaffold(
                  body: Builder(
                      builder: (context) => TextButton(
                            onPressed: () async {
                              selected = await showAppModalBottomSheet<int>(
                                context: context,
                                showDragHandle: true,
                                requestFocus: false,
                                builder: (_) => SafeArea(
                                    child: TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(42),
                                  child: const Text('选择'),
                                )),
                              );
                            },
                            child: const Text('打开'),
                          ))),
            ),
          ));
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<BottomSheet>(find.byType(BottomSheet))
                  .showDragHandle,
              isTrue);
          expect(find.byType(BackdropFilter),
              glass ? findsOneWidget : findsNothing);
          if (glass) {
            final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
            expect(sheet.backgroundColor!.a, closeTo(clean ? 1 : .7, .005));
          }
          await tester.tap(find.text('选择'));
          await tester.pumpAndSettle();
          expect(selected, 42);
          expect(find.byType(BottomSheet), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
