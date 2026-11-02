import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'load_test_fonts.dart';

Future<void> loadEmojiQAFonts() async {
  await loadTestFonts();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

Future<void> captureEmojiQA(
    WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['EMOJI_QA_DIR'];
  final images = tester
      .widgetList<Image>(find.byType(Image))
      .map((image) => image.image)
      .toList();
  // FileImage 的 native buffer 回调需要先推进测试帧，再进入真实 IO 区域。
  for (var frame = 0; frame < 4; frame++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.runAsync(() async {
    for (final image in images) {
      await precacheImage(image, key.currentContext!);
    }
  });
  await tester.pumpAndSettle();
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> waitForEmojiWork(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
