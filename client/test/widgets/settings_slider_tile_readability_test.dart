import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/settings/settings_section.dart';
import 'package:shenliyuan/widgets/settings/settings_slider_tile.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final viewport in [
    GoldenViewports.phone360x800,
    GoldenViewports.phone390x844,
    GoldenViewports.tabletPortrait768x1024
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('滑块说明与百分比之间有可读间隔 $viewport dark=$dark scale=$scale',
            (tester) async {
          await setGoldenViewport(tester, viewport);
          const subtitle = '模糊卡片背后的背景，强度越高越柔和，0% 关闭模糊';
          await tester.pumpWidget(GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(scale),
            home: Scaffold(
                body: ListView(padding: const EdgeInsets.all(16), children: [
              SettingsSection(children: [
                SettingsSliderTile(
                  icon: Icons.blur_on,
                  title: '毛玻璃强度',
                  subtitle: subtitle,
                  value: 1,
                  valueLabel: '100%',
                  onChanged: (_) {},
                )
              ])
            ])),
          ));
          await tester.pumpAndSettle();
          final hint = tester.getRect(find.text(subtitle));
          final value = tester.getRect(find.text('100%'));
          expect(value.left - hint.right, greaterThanOrEqualTo(4),
              reason: '真实中文字体在紧邻百分比时会显得粘连，必须保留阅读间隔');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
