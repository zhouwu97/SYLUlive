import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

Future<(ByteData, int)> _capture(
    WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final dir = Platform.environment['BACKGROUND_QA_DIR'];
      if (dir != null) {
        await Directory(dir).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$dir/$name.png').writeAsBytes(png.buffer.asUint8List());
      }
      return (bytes, image.width);
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('首页壁纸在键盘打开和收起时保持裁切，内容仍避让键盘', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
    final input = TextEditingController();
    addTearDown(input.dispose);
    final capture = GlobalKey();
    const contentKey = ValueKey('keyboard-content');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: RepaintBoundary(
                      key: capture,
                      child: Stack(fit: StackFit.expand, children: [
                        CustomBackgroundLayer(
                            canvasSize: MediaQuery.sizeOf(context)),
                        Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              key: contentKey,
                              width: 260,
                              child: TextField(
                                  controller: input,
                                  decoration:
                                      const InputDecoration(labelText: '搜索')),
                            )),
                      ]),
                    ),
                  ))),
    ));
    await tester.pumpAndSettle();
    final imageFinder = find.descendant(
        of: find.byType(CustomBackgroundLayer), matching: find.byType(Image));
    await tester.runAsync(() => precacheImage(
        tester.widget<Image>(imageFinder).image, tester.element(imageFinder)));
    await tester.pumpAndSettle();
    final original = tester.getRect(imageFinder);
    final before = await _capture(tester, capture, 'home-keyboard-before');
    final beforeBytes = before.$1;
    await tester.enterText(find.byType(TextField), '保留搜索');
    for (final inset in [300.0, 380.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expect(tester.getRect(imageFinder), original);
      expect(tester.getSize(find.byKey(capture)).height, 900 - inset);
      expect(input.text, '保留搜索');
      expect(tester.getBottomLeft(find.byKey(contentKey)).dy,
          lessThan(900 - inset));
      final after =
          await _capture(tester, capture, 'home-keyboard-${inset.toInt()}');
      final bytes = after.$1;
      // 比较输入框下方的真实壁纸像素，防止只保留 Widget 几何却重裁了图片。
      for (final y in [150, 300, 450]) {
        final offset = (y * after.$2 + 5) * 4;
        expect(bytes.buffer.asUint8List(offset, 4),
            beforeBytes.buffer.asUint8List(offset, 4));
      }
    }
    tester.view.physicalSize = const Size(900, 400);
    await tester.pumpAndSettle();
    expect(tester.getSize(imageFinder), const Size(900, 400));
    expect(tester.takeException(), isNull);
  });
}
