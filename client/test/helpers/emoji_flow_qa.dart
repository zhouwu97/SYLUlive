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
  await settleEmojiQAImages(tester, key.currentContext!, images);
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

/// 同时推进真实 IO 和测试帧；在 runAsync 中等待已在 fake-async 发起的解码会互相等待。
Future<void> settleEmojiQAImages(WidgetTester tester, BuildContext context,
    Iterable<ImageProvider> images) async {
  final pending = images.toSet();
  final listeners = <ImageStream, ImageStreamListener>{};
  final errors = <Object>[];
  try {
    for (final provider in pending.toList()) {
      final stream = provider.resolve(createLocalImageConfiguration(context));
      final listener = ImageStreamListener((_, __) => pending.remove(provider),
          onError: (Object error, StackTrace? stack) {
        errors.add(error);
        pending.remove(provider);
      });
      listeners[stream] = listener;
      stream.addListener(listener);
    }
    for (var i = 0; i < 300 && pending.isNotEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(pending, isEmpty, reason: '图片解码未在限定等待内完成');
    expect(errors, isEmpty, reason: '真实图片加载失败');
  } finally {
    for (final entry in listeners.entries) {
      entry.key.removeListener(entry.value);
    }
  }
}

Future<void> waitForEmojiWork(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.text('正在保存本机草稿…').evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}
