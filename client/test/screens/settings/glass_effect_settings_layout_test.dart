import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/bottom_navigation_settings_screen.dart';
import 'package:shenliyuan/screens/settings/frosted_glass_settings_screen.dart';
import 'package:shenliyuan/widgets/settings/settings_effect_option.dart';
import 'package:shenliyuan/widgets/settings/settings_effect_preview.dart';

import '../../helpers/golden_viewport.dart';

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('两类玻璃预设对齐，卡片页不再重复预览 dark=$dark scale=$scale', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        AppPreferencesStore.setMockInitialValues({});
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setFrostedGlass(true);
        double? optionWidth;
        double? titleOffset;
        for (final frosted in [true, false]) {
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: frosted
                  ? const FrostedGlassSettingsScreen()
                  : const BottomNavigationSettingsScreen(),
            ),
          ));
          await tester.pumpAndSettle();
          expect(find.byType(SettingsEffectPreview),
              frosted ? findsNothing : findsOneWidget);
          expect(find.byType(Switch), frosted ? findsNothing : findsOneWidget);
          const title = '关';
          await tester.scrollUntilVisible(find.text(title), 180,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          final option = frosted
              ? find
                  .byType(SettingsEffectOption<FrostedGlassPerformanceMode>)
                  .first
              : find
                  .byType(SettingsEffectOption<BottomNavPerformanceMode>)
                  .first;
          final rect = tester.getRect(option);
          final offset = tester.getTopLeft(find.text(title)).dx - rect.left;
          optionWidth ??= rect.width;
          titleOffset ??= offset;
          expect(rect.width, optionWidth);
          expect(offset, titleOffset);
          expect(rect.height, greaterThanOrEqualTo(44));
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
