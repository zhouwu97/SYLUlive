import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/wallpaper_prefetch_service.dart';

class _BytesAdapter implements HttpClientAdapter {
  final List<int> bytes;

  _BytesAdapter(this.bytes);

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
}
