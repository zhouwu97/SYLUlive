import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/wallpaper_prefetch_service.dart';

class _BytesAdapter implements HttpClientAdapter {
  final List<int> bytes;
  final int? declaredLength;

  _BytesAdapter(this.bytes, {this.declaredLength});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
        if (declaredLength != null)
          Headers.contentLengthHeader: ['$declaredLength'],
      },
    );
  }
}

void main() {
  test('截断但带 PNG 魔数的文件不能通过完整校验', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-verify-');
    final file = File('${directory.path}${Platform.pathSeparator}broken.png');
    try {
      await file.writeAsBytes(
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
        flush: true,
      );

      expect(await WallpaperPrefetchService.isValidImageFile(file), isTrue);
      expect(
        await WallpaperPrefetchService.isValidImageFile(
          file,
          fullDecode: true,
        ),
        isFalse,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('下载到临时文件的截断图片不会提升为正式缓存', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-download-');
    final targetPath =
        '${directory.path}${Platform.pathSeparator}broken-download.png';
    final dio = Dio()
      ..httpClientAdapter = _BytesAdapter(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0,
        0,
        0,
        0,
      ]);
    try {
      await expectLater(
        WallpaperPrefetchService.downloadAndVerifyImage(
          dio,
          'https://example.test/broken.png',
          targetPath,
        ),
        throwsException,
      );
      expect(await File(targetPath).exists(), isFalse);
      expect(await File('$targetPath.download').exists(), isFalse);
    } finally {
      dio.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('输入像素超过上限时在完整解码前拒绝图片', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-pixels-');
    final file = File('${directory.path}${Platform.pathSeparator}huge.png');
    const width = WallpaperPrefetchService.maxInputPixels;
    const height = 2;
    try {
      await file.writeAsBytes([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0,
        0,
        0,
        13,
        0x49,
        0x48,
        0x44,
        0x52,
        (width >> 24) & 0xFF,
        (width >> 16) & 0xFF,
        (width >> 8) & 0xFF,
        width & 0xFF,
        (height >> 24) & 0xFF,
        (height >> 16) & 0xFF,
        (height >> 8) & 0xFF,
        height & 0xFF,
        8,
        2,
        0,
        0,
        0,
      ]);

      expect(await WallpaperPrefetchService.isValidImageFile(file), isFalse);
      expect(
        await WallpaperPrefetchService.isValidImageFile(file, fullDecode: true),
        isFalse,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Content-Length 超过下载上限时不创建正式缓存', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-size-limit-');
    final targetPath =
        '${directory.path}${Platform.pathSeparator}too-large.png';
    final dio = Dio()
      ..httpClientAdapter = _BytesAdapter(
        const <int>[0x89, 0x50, 0x4E, 0x47],
        declaredLength: 20 * 1024 * 1024 + 1,
      );
    try {
      await expectLater(
        WallpaperPrefetchService.downloadAndVerifyImage(
          dio,
          'https://example.test/too-large.png',
          targetPath,
        ),
        throwsException,
      );
      expect(await File(targetPath).exists(), isFalse);
      expect(await File('$targetPath.download').exists(), isFalse);
    } finally {
      dio.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
