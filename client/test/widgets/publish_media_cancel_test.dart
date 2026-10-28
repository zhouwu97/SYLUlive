import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/publish_image_item.dart';
import 'package:shenliyuan/screens/publish/widgets/publish_image_grid.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';

// 交互测试使用不可用图片，证明加载失败也不能挡住取消入口；不访问真实网络或缓存。
class _UnavailableImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(String url,
          {String? key,
          Map<String, String>? headers,
          bool withProgress = false}) =>
      Stream<FileResponse>.error(
          const FileSystemException('fixture image unavailable'));
}

List<PublishImageItem> _images() => [
      for (final state in PublishImageUploadState.values)
        PublishImageItem.local(
            XFile('/nonexistent/cancel-${state.name}.png'), state.name)
          ..uploadState = state
          ..progress = state == PublishImageUploadState.uploading ? 0.45 : 0
          ..uploadError = state == PublishImageUploadState.failed
              ? const UploadImageResult.failure(message: '网络中断')
              : null
          ..fileId = state == PublishImageUploadState.success ? 10 : null,
      PublishImageItem.existing(PostImage(
        id: 90,
        postId: 1,
        fileId: 100,
        file: FileItem(
            id: 100,
            hash: '',
            path: '/uploads/unavailable-cancel.png',
            size: 100,
            mimeType: 'image/png'),
      )),
    ];

Widget _app({
  required List<PublishImageItem> images,
  required bool singleSlot,
  required ValueChanged<String> onRemove,
  ValueChanged<String>? onRetry,
  ValueChanged<int>? onPreview,
  bool canRemove = true,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
}) =>
    GoldenTestApp(
      themeMode: themeMode,
      textScaler: TextScaler.linear(textScale),
      home: Scaffold(
          body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PublishImageGrid(
          images: images,
          singleSlot: singleSlot,
          canAddMore: false,
          canRemove: canRemove,
          onAdd: () {},
          onRemove: onRemove,
          onReorder: (_, __) {},
          onRetry: onRetry,
          onPreviewImage: onPreview,
        ),
      )),
    );

Finder _remove(PublishImageItem item) =>
    find.byKey(ValueKey('publish-image-remove-${item.id}'));

void main() {
  setUpAll(() {
    // 各测试文件有独立 isolate，不读取默认值，避免惰性构造真实磁盘缓存。
    CachedNetworkImageProvider.defaultCacheManager = _UnavailableImageCache();
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final singleSlot in [false, true]) {
    final layout = singleSlot ? '单图' : '网格';
    for (final profile in [
      ('light', ThemeMode.light, 1.0),
      ('dark-large', ThemeMode.dark, 1.3),
    ]) {
      testWidgets('$layout ${profile.$1} 五种图片状态都能取消且命中区至少44px', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final removed = <String>[];
        final retries = <String>[];
        final previews = <int>[];
        final images = _images();
        // 单槽一次只显示一张；普通网格同时验证各项叠层与稳定 ID。
        final batches = singleSlot ? images.map((item) => [item]) : [images];
        for (final batch in batches) {
          await tester.pumpWidget(_app(
            images: batch,
            singleSlot: singleSlot,
            onRemove: removed.add,
            onRetry: retries.add,
            onPreview: previews.add,
            themeMode: profile.$2,
            textScale: profile.$3,
          ));
          await tester.pump();
          for (final item in batch) {
            final button = tester.widget<IconButton>(_remove(item));
            expect(button.onPressed, isNotNull, reason: '${item.id} 必须能取消');
            final tooltip = item.source == PublishImageSource.existing
                ? '移除'
                : switch (item.uploadState) {
                    PublishImageUploadState.waiting => '取消等待',
                    PublishImageUploadState.uploading => '取消上传',
                    PublishImageUploadState.failed ||
                    PublishImageUploadState.success =>
                      '移除',
                  };
            expect(button.tooltip, contains(tooltip));
            final size = tester.getSize(_remove(item));
            expect(size.width, greaterThanOrEqualTo(44));
            expect(size.height, greaterThanOrEqualTo(44));
            await tester.tap(_remove(item));
            await tester.pump();
            expect(removed.last, item.id);
          }
        }
        expect(removed, images.map((item) => item.id).toList());
        expect(retries, isEmpty, reason: '取消不能误触发失败重试');
        expect(previews, isEmpty, reason: '取消不能透传为图片预览');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }

    testWidgets('$layout 失败重试与取消各自只触发对应回调', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final failed = _images().firstWhere(
          (item) => item.uploadState == PublishImageUploadState.failed);
      final removed = <String>[];
      final retries = <String>[];
      await tester.pumpWidget(_app(
        images: [failed],
        singleSlot: singleSlot,
        onRemove: removed.add,
        onRetry: retries.add,
      ));
      await tester.pump();
      await tester.tap(find.text('上传失败，点击重试'));
      await tester.pump();
      expect(retries, [failed.id]);
      expect(removed, isEmpty);
      await tester.tap(_remove(failed));
      await tester.pump();
      expect(removed, [failed.id]);
      expect(retries, [failed.id]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('$layout canRemove为false时各状态移除按钮明确禁用', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final removed = <String>[];
      final images = _images();
      final batches = singleSlot ? images.map((item) => [item]) : [images];
      for (final batch in batches) {
        await tester.pumpWidget(_app(
          images: batch,
          singleSlot: singleSlot,
          canRemove: false,
          onRemove: removed.add,
        ));
        await tester.pump();
        for (final item in batch) {
          expect(_remove(item), findsOneWidget);
          expect(tester.widget<IconButton>(_remove(item)).onPressed, isNull);
          await tester.tap(_remove(item));
          await tester.pump();
        }
      }
      expect(removed, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
