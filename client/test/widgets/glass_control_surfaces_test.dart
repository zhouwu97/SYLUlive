import '../helpers/active_backdrop_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/app_choice_chip.dart';
import 'package:shenliyuan/widgets/app_glass_button_style.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final dark in [false, true]) {
    for (final clean in [false, true]) {
      testWidgets('玻璃筛选、按钮保持实色前景和点击键盘状态 dark=$dark clean=$clean',
          (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        AppPreferencesStore.setMockInitialValues({});
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        if (clean) await appearance.setCleanBackgroundMode();
        await appearance.setFrostedGlass(true);
        var selected = true;
        var enabled = true;
        var pressed = 0;
        late StateSetter change;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: MaterialApp(
            theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
            home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
              change = setState;
              return Column(children: [
                AppChoiceChip(
                  label: const Text('全部'),
                  selected: selected,
                  selectedColor: const Color(0xFF147C72),
                  labelStyle: TextStyle(color: selected ? Colors.white : null),
                  onSelected: (value) => setState(() => selected = value),
                ),
                FilledButton(
                  focusNode: focus,
                  style: appGlassButtonStyle(
                      context,
                      FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF147C72),
                        foregroundColor: Colors.white,
                      )),
                  onPressed: enabled ? () => pressed++ : null,
                  child: const Text('保存'),
                ),
              ]);
            })),
          ),
        ));
        await tester.pumpAndSettle();
        expect(
            Theme.of(tester.element(find.text('全部'))).canvasColor,
            clean
                ? (dark ? AppTheme.darkTheme : AppTheme.lightTheme).canvasColor
                : Colors.transparent,
            reason: '简洁模式恢复原底色，自定义背景不能被 RawChip 默认 Material 遮住');
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        final foreground = button.style!.foregroundColor!.resolve({})!;
        expect(foreground.a, 1, reason: '透明度只用于按钮底面');
        expect(button.style!.backgroundColor!.resolve({}),
            clean ? const Color(0xFF147C72) : Colors.transparent);
        expect(button.style!.backgroundBuilder, clean ? isNull : isNotNull);
        expect(
            tester
                .widgetList<Opacity>(find.byType(Opacity))
                .every((opacity) => opacity.opacity == 1),
            isTrue,
            reason: '静止状态只调整底面透明度，前景保持清晰');
        final filters =
            tester.widgetList<BackdropFilter>(activeBackdropFilters());
        expect(filters, hasLength(clean ? 0 : 2));
        expect(filters.every((filter) => filter.blendMode == BlendMode.src),
            isTrue);
        await tester.tap(find.text('全部'));
        await tester.pumpAndSettle();
        expect(selected, false);
        await tester.tap(find.text('保存'));
        expect(pressed, 1);
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(pressed, 2);
        change(() => enabled = false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存'));
        expect(pressed, 2);
        await appearance.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(activeBackdropFilters(), findsNothing);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
