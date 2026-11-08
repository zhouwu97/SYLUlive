import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_input_surface.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final kind in ['text', 'form', 'dropdown']) {
      testWidgets('$kind 浮动标签与原生输入框一样完整 dark=$dark', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(1);
        final capture = GlobalKey();
        final controller = TextEditingController(text: '自动识别');
        addTearDown(controller.dispose);
        final focus = FocusNode();
        addTearDown(focus.dispose);

        Widget input(bool wrapped) {
          final decoration = InputDecoration(
            labelText: '请求协议',
            labelStyle: TextStyle(color: dark ? Colors.white : Colors.black),
            floatingLabelStyle:
                TextStyle(color: dark ? Colors.white : Colors.black),
            floatingLabelBehavior: FloatingLabelBehavior.always,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            border: const OutlineInputBorder(),
            enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.grey)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.grey)),
          );
          return switch (kind) {
            'dropdown' => DropdownButtonFormField<int>(
                initialValue: 1,
                decoration: decoration,
                items: const [DropdownMenuItem(value: 1, child: Text('自动识别'))],
                onChanged: (_) {},
              ),
            'form' => TextFormField(
                controller: wrapped ? controller : null,
                initialValue: wrapped ? null : '自动识别',
                focusNode: wrapped ? focus : null,
                decoration: decoration,
              ),
            _ => TextField(
                controller: wrapped ? controller : null,
                focusNode: wrapped ? focus : null,
                decoration: decoration,
              ),
          };
        }

        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(dark ? 1.3 : 1),
              home: Scaffold(
                backgroundColor: dark ? const Color(0xFF1E2226) : Colors.white,
                body: Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: AppInputSurface(child: input(true))),
                        const SizedBox(width: 10),
                        Expanded(child: input(false)),
                      ]),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final fields = find.byType(InputDecorator);
        final originalRect = tester.getRect(fields.first);
        if (kind != 'dropdown') focus.requestFocus();
        for (final glass in [false, true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          final wrapped = tester.getRect(fields.first);
          final native = tester.getRect(fields.last);
          expect(wrapped, originalRect);
          if (kind != 'dropdown') {
            expect(focus.hasFocus, isTrue);
            expect(controller.text, '自动识别');
          }
          await tester.runAsync(() async {
            final boundary = capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final rgba =
                (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
            int labelInk(Rect rect) {
              var count = 0;
              // 比较上浮到边框以外的文字，原生对照组保留完全相同的边框和字号。
              for (var y = rect.top.floor() - 12; y < rect.top + 3; y++) {
                for (var x = rect.left.floor() + 12; x < rect.left + 100; x++) {
                  final r = rgba.getUint8((y * image.width + x) * 4);
                  if (dark ? r > 110 : r < 150) count++;
                }
              }
              return count;
            }

            final actualInk = labelInk(wrapped),
                referenceInk = labelInk(native);
            expect(referenceInk, greaterThan(20));
            expect(actualInk, closeTo(referenceInk, referenceInk * .08),
                reason: '玻璃底面不能裁掉浮动标签伸到边框外的上半部分');
            final dir = Platform.environment['BACKGROUND_QA_DIR'];
            if (dir != null) {
              await Directory(dir).create(recursive: true);
              final png =
                  (await image.toByteData(format: ui.ImageByteFormat.png))!;
              await File('$dir/input-$kind-$dark-$glass.png')
                  .writeAsBytes(png.buffer.asUint8List());
            }
            image.dispose();
          });
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
