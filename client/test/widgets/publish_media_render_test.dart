import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/models/publish_image_item.dart';
import 'package:shenliyuan/screens/publish/widgets/publish_image_grid.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _output = String.fromEnvironment('MEDIA_QA_OUTPUT');
const _fixtures = String.fromEnvironment('MEDIA_QA_FIXTURES');

void main() {
  setUpAll(loadTestFonts);
  for (final profile in [
    ('light', ThemeMode.light, 1.0),
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3),
    ('stress', ThemeMode.dark, 1.5),
  ]) {
    testWidgets('九图预上传状态与单图恢复实际布局 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final root = await tester
          .runAsync(() => Directory.systemTemp.createTemp('media-render-'));
      final file = File('${root!.path}/photo.png');
      await tester.runAsync(() async {
        final pixels = image.fill(image.Image(width: 360, height: 240),
            color: image.ColorRgb8(62, 150, 135));
        image.fillRect(pixels,
            x1: 45,
            y1: 40,
            x2: 310,
            y2: 180,
            color: image.ColorRgb8(224, 243, 230));
        await file.writeAsBytes(image.encodePng(pixels));
      });
      addTearDown(() async {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await root.delete(recursive: true);
        });
      });
      final images = List.generate(
          9,
          (i) => PublishImageItem.local(XFile(_fixtures.isEmpty ? file.path : '$_fixtures/${i.isEven ? 'photo' : 'alpha'}.png'), 'photo-$i')
            ..uploadState = PublishImageUploadState.success);
      // 在真实异步区完成本地解码，再挂载 Widget；避免文件读取跨 FakeAsync
      // 边界留下尚未完成的图像流，截图时只看到占位背景。
      await tester.runAsync(() async {
        for (final path in images.map((e) => e.localFile!.path).toSet()) {
          for (final size in [512, 640]) {
            final provider = ResizeImage(FileImage(File(path)), width: size,
              height: size, policy: ResizeImagePolicy.fit);
            final loaded = Completer<void>();
            final stream = provider.resolve(const ImageConfiguration());
            late final ImageStreamListener listener;
            listener = ImageStreamListener((_, __) => loaded.complete(),
              onError: (Object error, StackTrace? stack) => loaded.completeError(error, stack));
            stream.addListener(listener);
            await loaded.future;
            stream.removeListener(listener);
          }
        }
      });
      images[0].uploadState = PublishImageUploadState.uploading;
      images[0].progress = 0.45;
      images[1].uploadState = PublishImageUploadState.waiting;
      images[2].uploadState = PublishImageUploadState.failed;
      images[2].uploadError =
          const UploadImageResult.failure(message: '网络中断，请重试');
      var retries = 0;
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('media-qa'),
        child: GoldenTestApp(
          themeMode: profile.$2,
          textScaler: TextScaler.linear(profile.$3),
          home: Scaffold(
            appBar: AppBar(title: const Text('图片发布')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('图片 9/9'),
                    const SizedBox(height: 8),
                    PublishImageGrid(
                        images: images,
                        canAddMore: false,
                        onAdd: () {},
                        onRemove: (_) {},
                        onReorder: (_, __) {},
                        onRetry: (_) => retries++),
                    const SizedBox(height: 16),
                    const Text('单图上传失败也可直接重试'),
                    const SizedBox(height: 8),
                    PublishImageGrid(
                        images: [images[2]],
                        canAddMore: false,
                        singleSlot: true,
                        onAdd: () {},
                        onRemove: (_) {},
                        onReorder: (_, __) {},
                        onRetry: (_) => retries++),
                  ]),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('上传 45%'), findsOneWidget);
      expect(find.text('等待上传'), findsOneWidget);
      expect(find.text('上传失败，点击重试'), findsNWidgets(2));
      final decodedImages =
          tester.widgetList<Image>(find.byType(Image)).toList();
      expect(decodedImages, hasLength(10));
      expect(tester.widgetList<RawImage>(find.byType(RawImage))
          .where((e) => e.image != null), hasLength(10));
      for (final photo in decodedImages) {
        expect(photo.image, isA<ResizeImage>());
        final bounded = photo.image as ResizeImage;
        expect(bounded.width, lessThanOrEqualTo(640));
        expect(bounded.height, lessThanOrEqualTo(640));
        expect(bounded.policy, ResizeImagePolicy.fit);
      }
      expect(tester.takeException(), isNull);
      if (_output.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('media-qa')));
        await tester.runAsync(() async {
          final rendered = await boundary.toImage(pixelRatio: 1);
          final bytes =
              await rendered.toByteData(format: ui.ImageByteFormat.png);
          rendered.dispose();
          await Directory(_output).create(recursive: true);
          await File('$_output/media-${profile.$1}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.tap(find.text('上传失败，点击重试').first);
      await tester.tap(find.text('上传失败，点击重试').last);
      expect(retries, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
