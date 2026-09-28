import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

class _StreamAdapter implements HttpClientAdapter {
  final Stream<Uint8List> stream;
  _StreamAdapter(this.stream);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }
}

List<int> _le32(int value) => <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

List<int> _ascii(String value) => value.codeUnits;

List<int> _losslessWebp() => base64Decode(
      'UklGRlAAAABXRUJQVlA4TEMAAAAv/8P/AAdQkTIUp/8BgUCyv/kERfQ/4z//+c9//vOf//znP//5z3/+85///Oc///nPf/7zn//85z//+c9//vOf//zfAA==',
    );

List<int> _largeLosslessWebp() {
  final image = img.Image(width: 1024, height: 1024);
  var seed = 0x13579BDF;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
      image.setPixelRgb(
        x,
        y,
        seed & 0xFF,
        (seed >> 8) & 0xFF,
        (seed >> 16) & 0xFF,
      );
    }
  }
  return img.encodeWebP(image);
}

List<int> _losslessWebpHeader({required int width, required int height}) {
  final bits = (width - 1) | ((height - 1) << 14);
  final payload = <int>[0x2F, ..._le32(bits)];
  final body = <int>[
    ..._ascii('VP8L'),
    ..._le32(payload.length),
    ...payload,
    if (payload.length.isOdd) 0,
  ];
  return <int>[
    ..._ascii('RIFF'),
    ..._le32(body.length + 4),
    ..._ascii('WEBP'),
    ...body,
  ];
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

  test('无损 WebP 的两个连续 14 位尺寸字段按规范解析', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-webp-metadata-');
    final file = File('${directory.path}${Platform.pathSeparator}valid.webp');
    try {
      await file.writeAsBytes(_losslessWebp(), flush: true);
      expect(
        await WallpaperPrefetchService.isValidImageFile(
          file,
          fullDecode: true,
        ),
        isTrue,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('大于 1 MiB 的有效无损 WebP 压缩块可以完成校验', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-webp-chunk-');
    final file = File('${directory.path}${Platform.pathSeparator}large.webp');
    try {
      final bytes = _largeLosslessWebp();
      expect(bytes.length, greaterThan(1024 * 1024));
      await file.writeAsBytes(bytes, flush: true);
      expect(
        await WallpaperPrefetchService.isValidImageFile(
          file,
          fullDecode: true,
        ),
        isTrue,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('无损 WebP 真实像素超过输入上限时不能被错误低估', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-webp-pixels-');
    final file = File('${directory.path}${Platform.pathSeparator}huge.webp');
    try {
      await file.writeAsBytes(
        _losslessWebpHeader(width: 8000, height: 4001),
        flush: true,
      );
      expect(await WallpaperPrefetchService.isValidImageFile(file), isFalse);
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

  test('无 Content-Length 且流式累计超过上限时停止接收并清理临时文件', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-stream-limit-');
    final targetPath =
        '${directory.path}${Platform.pathSeparator}stream-overflow.png';
    Stream<Uint8List> generateInfiniteChunks() async* {
      final chunk = Uint8List(1024 * 1024);
      chunk.fillRange(0, chunk.length, 0xAA);
      for (var i = 0; i < 25; i++) {
        yield chunk;
      }
    }

    final dio = Dio()
      ..httpClientAdapter = _StreamAdapter(generateInfiniteChunks());
    try {
      await expectLater(
        WallpaperPrefetchService.downloadAndVerifyImage(
          dio,
          'https://example.test/stream-overflow.png',
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

  test('下载中途取消时不遗留临时文件', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-cancel-');
    final targetPath =
        '${directory.path}${Platform.pathSeparator}cancel-download.png';
    final cancelToken = CancelToken();
    Stream<Uint8List> slowStream() async* {
      yield Uint8List(1024);
      cancelToken.cancel('user cancel');
      yield Uint8List(1024);
    }

    final dio = Dio()..httpClientAdapter = _StreamAdapter(slowStream());
    try {
      await expectLater(
        WallpaperPrefetchService.downloadAndVerifyImage(
          dio,
          'https://example.test/cancel.png',
          targetPath,
          cancelToken: cancelToken,
        ),
        throwsA(anyOf(isA<DioException>(), isA<StateError>())),
      );
      expect(await File(targetPath).exists(), isFalse);
      expect(await File('$targetPath.download').exists(), isFalse);
    } finally {
      dio.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('VP8L 非零规范版本号被拒绝', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-webp-version-');
    final file = File('${directory.path}${Platform.pathSeparator}invalid-ver.webp');
    try {
      const bits = (100 - 1) | ((100 - 1) << 14) | (1 << 29); // version = 1
      final payload = <int>[0x2F, ..._le32(bits)];
      final body = <int>[
        ..._ascii('VP8L'),
        ..._le32(payload.length),
        ...payload,
      ];
      final bytes = <int>[
        ..._ascii('RIFF'),
        ..._le32(body.length + 4),
        ..._ascii('WEBP'),
        ...body,
      ];
      await file.writeAsBytes(bytes, flush: true);
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

  test('有效 VP8 有损格式正常提取尺寸', () async {
    final directory =
        await Directory.systemTemp.createTemp('wallpaper-webp-vp8-');
    final file = File('${directory.path}${Platform.pathSeparator}lossy.webp');
    try {
      const width = 640;
      const height = 480;
      final payload = <int>[
        0x00, 0x00, 0x00,
        0x9D, 0x01, 0x2A,
        width & 0xFF, (width >> 8) & 0x3F,
        height & 0xFF, (height >> 8) & 0x3F,
      ];
      final body = <int>[
        ..._ascii('VP8 '),
        ..._le32(payload.length),
        ...payload,
      ];
      final bytes = <int>[
        ..._ascii('RIFF'),
        ..._le32(body.length + 4),
        ..._ascii('WEBP'),
        ...body,
      ];
      await file.writeAsBytes(bytes, flush: true);
      expect(await WallpaperPrefetchService.isValidImageFile(file), isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
