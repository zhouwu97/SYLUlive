import '../helpers/active_backdrop_filters.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';

import '../helpers/golden_viewport.dart';

Future<int> _sample(
    WidgetTester tester, GlobalKey capture, Offset point, String name) async {
  return (await tester.runAsync(() async {
    final image = await (capture.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage();
    try {
      final bytes = (await image.toByteData())!;
      final i = (point.dy.round() * image.width + point.dx.round()) * 4;
      final output = Platform.environment['BACKGROUND_QA_DIR'];
      if (output != null) {
        await Directory(output).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$output/$name.png').writeAsBytes(png.buffer.asUint8List());
      }
      return bytes.getUint8(i);
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final reduced in [false, true]) {
    testWidgets('玻璃弹窗中间帧无黑块，关闭恢复背景 reduced=$reduced', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setComponentOpacity(.25);
      await theme.setFrostedGlass(true);
      final capture = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: RepaintBoundary(
            key: capture,
            child: MaterialApp(
              navigatorKey: navigator,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: reduced),
                  child: child!),
              home: Scaffold(
                  backgroundColor: const Color(0xFFB0B0B0),
                  body: Builder(
                      builder: (context) => TextButton(
                          onPressed: () => showAppDialog<void>(
                              context: context,
                              builder: (_) => const AppDialog(
                                  backgroundColor: Colors.white,
                                  child: SizedBox(width: 240, height: 200))),
                          child: const Text('打开')))),
            )),
      ));
      await tester.pumpAndSettle();
      const point = Offset(195, 422);
      final before = await _sample(tester, capture, point, 'before-$reduced');
      await tester.tap(find.text('打开'));
      await tester.pump();
      for (var phase = 0; phase < 2; phase++) {
        if (phase == 1) {
          await tester.pumpAndSettle();
          navigator.currentState!.pop();
          await tester.pump();
        }
        for (var frame = 0; frame < (reduced ? 2 : 15); frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final inside = await _sample(
              tester, capture, point, 'dialog-$reduced-$phase-$frame');
          final outside = await _sample(tester, capture, const Offset(12, 422),
              'backdrop-$reduced-$phase-$frame');
          expect(inside, greaterThanOrEqualTo(outside - 2),
              reason: '白色玻璃底面不能比遮罩后的背景更暗');
          for (final filter in activeBackdropFilters().evaluate()) {
            var hasOpacity = false;
            filter.visitAncestorElements((element) {
              final widget = element.widget;
              if ((widget is Opacity && widget.opacity < 1) ||
                  (widget is FadeTransition && widget.opacity.value < 1)) {
                hasOpacity = true;
              }
              return true;
            });
            expect(hasOpacity, isFalse);
          }
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
      expect(
          await _sample(tester, capture, point, 'restored-$reduced'), before);
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(activeBackdropFilters(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
