import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/message_image_sizing.dart';
import 'package:shenliyuan/widgets/private_message_image.dart';

/// 1×1 透明 PNG，用于在测试环境里产生一个真实可解码的本地图片来源。
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String pixelPath;

  setUpAll(() async {
    // 文件 I/O 是真实异步，必须在 fake-async 测试区之外创建。
    tempDir = await Directory.systemTemp.createTemp('pm_image_test');
    pixelPath = '${tempDir.path}/pixel.png';
    await File(pixelPath).writeAsBytes(base64Decode(_onePixelPngBase64));
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  testWidgets('hit area equals the exact server-sized image box', (tester) async {
    var taps = 0;
    // 720×2400 旧图 → display == constrainImageDisplaySize(720×2400, 260×320)
    // = 96×320。可点击区域必须严格等于该图片框，而不是背后一个 260×260 方块。
    const maxWidth = 260.0;
    const maxHeight = 320.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PrivateMessageImage(
              localPath: pixelPath,
              serverWidth: 720,
              serverHeight: 2400,
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(find.byType(PrivateMessageImage));
    final expected = constrainImageDisplaySize(
      src: const Size(720, 2400),
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    expect(rect.width, closeTo(expected.width, 1));
    expect(rect.height, closeTo(expected.height, 1));
    expect(rect.width, lessThanOrEqualTo(260));
    expect(rect.height, closeTo(320, 1));

    // 点击图片中心 → 打开
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(taps, 1);

    // 点击图片外 20dp（右侧、上方空白）→ 不能打开
    await tester.tapAt(Offset(rect.right + 20, rect.center.dy));
    await tester.pump();
    await tester.tapAt(Offset(rect.center.dx, rect.top - 20));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets(
      'network-only image with no server size is not tappable before resolution',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PrivateMessageImage(
              networkUrl: '/api/messages/files/1',
              maxWidth: 260,
              maxHeight: 320,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 尺寸尚未解析完成：外层不绑定打开大图的点击，仅显示 loading/失败占位。
    final detector = tester.widget<GestureDetector>(
      find.descendant(
        of: find.byType(PrivateMessageImage),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(detector.onTap, isNull);
    await tester.pump();
  });
}
