import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file/file.dart' as pkg_file;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/utils/image_decode_size.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';
import 'package:shenliyuan/utils/private_message_media_cache.dart';

class _TrackingFakeCacheManager extends Fake implements BaseCacheManager {
  final Map<String, FileInfo> store = {};
  final List<String> requestedKeys = [];
  final MemoryFileSystem fs = MemoryFileSystem();

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    requestedKeys.add(key);
    return store[key];
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    return const Stream.empty();
  }

  pkg_file.File putSync(String key, List<int> bytes) {
    final file = fs.file('/tmp/$key')..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    store[key] = FileInfo(
      file,
      FileSource.Online,
      DateTime.now().add(const Duration(days: 1)),
      key,
    );
    return file;
  }
}

class _CacheWriteFailingFakeCacheManager extends _TrackingFakeCacheManager {
  @override
  Future<pkg_file.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) {
    throw StateError('模拟缓存写入失败');
  }
}

/// 记录原图缓存写入的 key 与 maxAge，用于断言写入落在独立原图缓存；
/// 不消费下载流，返回内存文件即可（读取路径的真实存在性校验走真实文件）。
class _RecordingOriginalCacheManager extends _TrackingFakeCacheManager {
  final List<String> putKeys = [];
  final List<Duration> putMaxAges = [];
  int readCalls = 0;

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    readCalls++;
    return super.getFileFromCache(key, ignoreMemCache: ignoreMemCache);
  }

  @override
  Future<pkg_file.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    putKeys.add(key ?? url);
    putMaxAges.add(maxAge);
    return putSync(key ?? url, const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
  }
}

class _TrackingDownloadAdapter implements HttpClientAdapter {
  final List<String> requestedUrls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri.toString());
    return ResponseBody.fromBytes(
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      200,
      headers: {
        'content-length': ['4'],
        'content-type': ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ImmediateDownloadClient extends Fake implements Dio {
  final List<String> requestedUrls = [];

  @override
  Future<Response> download(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) async {
    requestedUrls.add(urlPath);
    File(savePath as String).writeAsBytesSync(
      const <int>[0xFF, 0xD8, 0xFF, 0xD9],
    );
    onReceiveProgress?.call(4, 4);
    return Response(
      requestOptions: RequestOptions(path: urlPath),
      headers: Headers.fromMap(const <String, List<String>>{
        'content-type': <String>['image/jpeg'],
      }),
    );
  }
}

class _BlockingDownloadAdapter implements HttpClientAdapter {
  final List<String> requestedUrls = [];
  final List<String> cancelledUrls = [];
  final Set<String> activeUrls = <String>{};
  final Map<String, Completer<void>> _releases = {};
  int maxActiveRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requestedUrls.add(url);
    activeUrls.add(url);
    if (activeUrls.length > maxActiveRequests) {
      maxActiveRequests = activeUrls.length;
    }

    final release = Completer<void>();
    _releases[url] = release;
    final result = await Future.any<String>([
      release.future.then((_) => 'release'),
      if (cancelFuture != null) cancelFuture.then((_) => 'cancel'),
    ]);
    activeUrls.remove(url);
    if (result == 'cancel') {
      cancelledUrls.add(url);
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }

    return ResponseBody.fromBytes(
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      200,
      headers: {
        'content-length': ['4'],
        'content-type': ['image/jpeg'],
      },
    );
  }

  void release(String url) {
    final completer = _releases[url];
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void close({bool force = false}) {}
}

/// 分块下发响应：先到 33%/67% 两个进度，随后挂在门上等待
/// （取消时会放开），用于驱动按钮内的真实进度展示。
class _GatedChunkedDownloadAdapter implements HttpClientAdapter {
  final List<String> requestedUrls = [];
  final List<String> cancelledUrls = [];
  final Completer<void> _gate = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requestedUrls.add(url);
    cancelFuture?.whenComplete(() {
      cancelledUrls.add(url);
      if (!_gate.isCompleted) _gate.complete();
    });

    final controller = StreamController<Uint8List>();
    unawaited(Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      controller.add(Uint8List(1000));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      controller.add(Uint8List(1000));
      await _gate.future;
      controller.add(Uint8List(1000));
      await controller.close();
    }));
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        'content-length': ['3000'],
        'content-type': ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 取消/重试原图下载后，错误要穿过 dio 流清理、raf.close、.part 删除等
/// 层层串行的真实磁盘 I/O。假时钟环境里 pump 提交下一层 I/O，runAsync
/// 让真实事件循环送达完成事件，交替数轮后链路才能走完并重建 UI。
Future<void> _driveOriginalDownloadSettle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('gal'),
      (call) async {
        if (call.method == 'hasAccess' || call.method == 'requestAccess') {
          return true;
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        return '/tmp';
      },
    );
  });

  testWidgets('全屏私信图片保留 bearer token 并绑定账号专属私有缓存与 cacheKey', (tester) async {
    final fakePrivateCache = _TrackingFakeCacheManager();
    const testUrl = 'https://example.test/private.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          imageUrls: const [testUrl],
          httpHeaders: const {'Authorization': 'Bearer viewer-token'},
          cacheManager: fakePrivateCache,
          cacheKeyBuilder: (url) =>
              PrivateMessageMediaCache.cacheKeyFor(url, accountId: 42),
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    final resize = image.image as ResizeImage;
    final provider = resize.imageProvider as CachedNetworkImageProvider;
    expect(provider.headers, {'Authorization': 'Bearer viewer-token'});
    expect(provider.cacheManager, equals(fakePrivateCache));
    expect(provider.cacheKey, equals('pm:42:$testUrl'));
  });

  testWidgets('查看器等比限制解码长边，不按屏幕比例压扁位图', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: ImageViewerScreen(
          imageUrls: ['https://example.test/origin.jpg'],
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
    final resize = image.image as ResizeImage;
    expect(resize.policy, ResizeImagePolicy.fit);
    expect(resize.width, imageViewerLongEdge);
    expect(resize.height, imageViewerLongEdge);
  });

  testWidgets('GIF 查看不套用解码缩放，保留动画帧', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ImageViewerScreen(
          imageUrls: ['https://example.test/anim.gif'],
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<CachedNetworkImageProvider>());
  });

  testWidgets('全屏私信图片长按保存时，私有缓存未命中严禁回退到公开/默认缓存', (tester) async {
    final fakePrivateCache = _TrackingFakeCacheManager();
    const testUrl = 'https://example.test/private.jpg';
    final expectedCacheKey =
        PrivateMessageMediaCache.cacheKeyFor(testUrl, accountId: 99);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          imageUrls: const [testUrl],
          httpHeaders: const {'Authorization': 'Bearer viewer-token'},
          cacheManager: fakePrivateCache,
          cacheKeyBuilder: (url) =>
              PrivateMessageMediaCache.cacheKeyFor(url, accountId: 99),
        ),
      ),
    );
    await tester.pump();

    // 触发长按弹出菜单
    await tester.longPress(find.byType(InteractiveViewer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('保存原图'), findsOneWidget);
    // 点击保存原图（在测试环境中网络请求会失败，转而执行 _readCachedImage）
    await tester.tap(find.text('保存原图'));
    // 推进单帧与异步，等待 _saveImage 与 _readCachedImage 执行并释放超时定时器
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    // 验证：_readCachedImage 仅查询了私有 cacheManager 且使用的 key 是 account-scoped key
    expect(fakePrivateCache.requestedKeys, contains(expectedCacheKey));
  });

  testWidgets('刚发送的私信图片(仅本地文件路径，imageUrls为空)能够正常渲染 1/1 且不出现 RangeError',
      (tester) async {
    // 构造临时测试文件
    final tempDir = Directory.systemTemp.createTempSync('viewer_test');
    final testFile = File('${tempDir.path}/test_local.png');
    testFile.writeAsBytesSync([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // ...
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ImageViewerScreen(
            imageUrls: const [],
            localPaths: [testFile.path],
          ),
        ),
      );
      await tester.pump();

      // 断言标题显示 1 / 1 而不是 1 / 0
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);

      // 触发长按保存
      await tester.longPress(find.byType(InteractiveViewer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('保存原图'), findsOneWidget);

      await tester.tap(find.text('保存原图'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // 验证保存流程成功执行，没有未捕获异常
      expect(tester.takeException(), isNull);
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('ImageViewerScreen 支持结构化 items 列表与内存字节直存', (tester) async {
    final pngBytes = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          items: [
            ImageViewerItem(bytes: pngBytes),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  test('小于600KB的图片默认使用原图，边界值不自动加载', () {
    expect(
      shouldAutoLoadOriginalByDefault(
        originalSizeBytes: imageOriginalAutoLoadThresholdBytes - 1,
      ),
      isTrue,
    );
    expect(
      shouldAutoLoadOriginalByDefault(
        originalSizeBytes: imageOriginalAutoLoadThresholdBytes,
      ),
      isFalse,
    );
    expect(
      shouldAutoLoadOriginalByDefault(originalSizeBytes: 0),
      isFalse,
    );
    expect(
      shouldAutoLoadOriginalByDefault(
        originalSizeBytes: imageOriginalAutoLoadThresholdBytes,
        isAnimatedGif: true,
      ),
      isFalse,
    );
  });

  testWidgets('小于600KB的结构化图片进入查看器直接请求原图', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ImageViewerScreen(
          items: [
            ImageViewerItem(
              thumbUrl: 'https://example.test/image-thumb.jpg',
              previewUrl: 'https://example.test/image-medium.jpg',
              originalUrl: 'https://example.test/image-origin.jpg',
              originalSizeBytes: imageOriginalAutoLoadThresholdBytes - 1,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final original = tester.widget<Image>(
      find.byKey(const ValueKey('viewer-original-image-0')),
    );
    final resize = original.image as ResizeImage;
    final provider = resize.imageProvider as CachedNetworkImageProvider;
    expect(provider.url, 'https://example.test/image-origin.jpg');
    expect(find.textContaining('查看原图'), findsNothing);
  });

  testWidgets('600KB 及以上的结构化图片只显示预览并提供手动查看原图', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ImageViewerScreen(
          items: [
            ImageViewerItem(
              thumbUrl: 'https://example.test/image-thumb.jpg',
              previewUrl: 'https://example.test/image-medium.jpg',
              viewerUrl: 'https://example.test/image-viewer.jpg',
              originalUrl: 'https://example.test/image-origin.jpg',
              originalSizeBytes: imageOriginalAutoLoadThresholdBytes,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('查看原图 600.0 KB'), findsOneWidget);
    final imageProviders = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<ResizeImage>()
        .map((image) => image.imageProvider)
        .whereType<CachedNetworkImageProvider>()
        .map((provider) => provider.url)
        .toList();
    expect(imageProviders,
        isNot(contains('https://example.test/image-origin.jpg')));
    expect(imageProviders, contains('https://example.test/image-medium.jpg'));
    expect(imageProviders, contains('https://example.test/image-thumb.jpg'));
  });

  testWidgets('大 GIF 使用静态首帧预览，不能进入查看器就自动加载动画原图', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ImageViewerScreen(
          items: [
            ImageViewerItem(
              thumbUrl: 'https://example.test/motion-thumb.jpg',
              previewUrl: 'https://example.test/motion-medium.jpg',
              originalUrl: 'https://example.test/motion.gif',
              originalSizeBytes: 2 * 1024 * 1024,
              mimeType: 'image/gif',
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('viewer-original-image-0')), findsNothing);
    expect(find.text('查看原图 2.0 MB'), findsOneWidget);
    final urls = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<ResizeImage>()
        .map((image) => image.imageProvider)
        .whereType<CachedNetworkImageProvider>()
        .map((provider) => provider.url)
        .toList();
    expect(urls, contains('https://example.test/motion-medium.jpg'));
    expect(urls, isNot(contains('https://example.test/motion.gif')));
  });

  testWidgets('查看原图下载进度显示在按钮上，取消后可重试并完成', (tester) async {
    final cache = _TrackingFakeCacheManager();
    final adapter = _GatedChunkedDownloadAdapter();
    final client = Dio()..httpClientAdapter = adapter;
    const originalUrl = 'https://example.test/progress-origin.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          cacheManager: cache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              previewUrl: 'https://example.test/progress-medium.jpg',
              originalUrl: originalUrl,
              originalSizeBytes: imageOriginalAutoLoadThresholdBytes,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('查看原图 600.0 KB'), findsOneWidget);
    await tester.tap(find.text('查看原图 600.0 KB'));
    await tester.pump();
    expect(find.text('加载中…'), findsOneWidget);

    // dio 在真实磁盘写入完成后才回调进度（raf.writeFrom 的 then），
    // 假时钟只推进分块计时器；runAsync 让真实 I/O 有机会完成。
    await tester.pump(const Duration(milliseconds: 150));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.text('33%'), findsOneWidget);

    // 进度节流按真实时钟 100ms 判定，先走真实时间再推进假时钟取下一块。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.text('67%'), findsOneWidget);

    await tester.tap(find.text('67%'));
    await _driveOriginalDownloadSettle(tester);
    expect(find.text('查看原图 600.0 KB'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(adapter.cancelledUrls, contains(originalUrl));

    await tester.tap(find.text('查看原图 600.0 KB'));
    await _driveOriginalDownloadSettle(tester);
    expect(find.text('查看原图 600.0 KB'), findsNothing);
    expect(
      find.byKey(const ValueKey('viewer-original-file-0')),
      findsOneWidget,
    );
  });

  testWidgets('查看原图使用 Dio 磁盘下载并在完成后复用文件保存', (tester) async {
    final cache = _TrackingFakeCacheManager();
    final adapter = _TrackingDownloadAdapter();
    final client = Dio()..httpClientAdapter = adapter;
    const originalUrl = 'https://example.test/large-origin.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          cacheManager: cache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              thumbUrl: 'https://example.test/large-thumb.jpg',
              previewUrl: 'https://example.test/large-medium.jpg',
              originalUrl: originalUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看原图 1.0 MB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(adapter.requestedUrls, [originalUrl]);
    expect(find.text('查看原图 1.0 MB'), findsNothing);

    final requestCount = adapter.requestedUrls.length;
    await tester.tap(find.byTooltip('保存原图'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(adapter.requestedUrls.length, requestCount);
  });

  testWidgets('原图下载结果写入独立缓存并带 7 天有效期，不落展示缓存', (tester) async {
    final displayCache = _TrackingFakeCacheManager();
    final originalCache = _RecordingOriginalCacheManager();
    final adapter = _TrackingDownloadAdapter();
    final client = Dio()..httpClientAdapter = adapter;
    const originalUrl = 'https://example.test/isolated-origin.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          cacheManager: displayCache,
          originalCacheManager: originalCache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              thumbUrl: 'https://example.test/isolated-thumb.jpg',
              originalUrl: originalUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看原图 1.0 MB'));
    await _driveOriginalDownloadSettle(tester);

    expect(adapter.requestedUrls, [originalUrl]);
    expect(originalCache.readCalls, greaterThanOrEqualTo(1));
    expect(originalCache.putKeys, [originalUrl]);
    expect(originalCache.putMaxAges, [PostOriginalCache.stalePeriod]);
    expect(displayCache.store, isEmpty);
    expect(
      find.byKey(const ValueKey('viewer-original-file-0')),
      findsOneWidget,
    );
  });

  testWidgets('原图命中独立缓存时不再发起网络请求', (tester) async {
    final originalCache = _TrackingFakeCacheManager();
    final adapter = _TrackingDownloadAdapter();
    final client = Dio()..httpClientAdapter = adapter;
    const originalUrl = 'https://example.test/hit-origin.jpg';

    // 读取路径会用真实 dart:io 校验存在性，先落一个真实文件再挂进缓存记录。
    final realFile = File(
        '/tmp/viewer_original_hit_cache_${DateTime.now().microsecondsSinceEpoch}.jpg');
    realFile.writeAsBytesSync(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
    addTearDown(() {
      if (realFile.existsSync()) realFile.deleteSync();
    });
    originalCache.store[originalUrl] = FileInfo(
      originalCache.fs.file(realFile.path),
      FileSource.Online,
      DateTime.now().add(const Duration(days: 1)),
      originalUrl,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          originalCacheManager: originalCache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              thumbUrl: 'https://example.test/hit-thumb.jpg',
              originalUrl: originalUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看原图 1.0 MB'));
    // 命中判定要过真实文件 exists/length 检查，与下载链一样交替推进。
    await _driveOriginalDownloadSettle(tester);

    expect(adapter.requestedUrls, isEmpty);
    expect(
      find.byKey(const ValueKey('viewer-original-file-0')),
      findsOneWidget,
    );
    expect(find.text('查看原图 1.0 MB'), findsNothing);
  });

  testWidgets('翻页会取消上一张原图且同一查看器最多一个原图请求', (tester) async {
    final cache = _TrackingFakeCacheManager();
    final adapter = _BlockingDownloadAdapter();
    final client = Dio()..httpClientAdapter = adapter;
    const firstUrl = 'https://example.test/first-origin.jpg';
    const secondUrl = 'https://example.test/second-origin.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          cacheManager: cache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              previewUrl: 'https://example.test/first-medium.jpg',
              originalUrl: firstUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
            ImageViewerItem(
              previewUrl: 'https://example.test/second-medium.jpg',
              originalUrl: secondUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看原图 1.0 MB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(adapter.activeUrls, contains(firstUrl));

    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();
    expect(adapter.cancelledUrls, contains(firstUrl));
    expect(adapter.activeUrls, isNot(contains(firstUrl)));

    await tester.tap(find.text('查看原图 1.0 MB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(adapter.activeUrls, contains(secondUrl));
    expect(adapter.maxActiveRequests, 1);

    adapter.release(secondUrl);
    await tester.pumpAndSettle();
    expect(find.text('查看原图 1.0 MB'), findsNothing);
  });

  testWidgets('缓存写入失败时查看原图保留正式文件，不把 .part 交给后续流程', (tester) async {
    final temporaryDirectory = await getTemporaryDirectory();
    final filesBefore = temporaryDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('sylulive_original_'))
        .map((file) => file.path)
        .toSet();
    final cache = _CacheWriteFailingFakeCacheManager();
    final client = _ImmediateDownloadClient();
    const originalUrl = 'https://example.test/cache-fallback-origin.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          cacheManager: cache,
          downloadClient: client,
          items: const [
            ImageViewerItem(
              previewUrl: 'https://example.test/cache-fallback-medium.jpg',
              originalUrl: originalUrl,
              originalSizeBytes: 1024 * 1024,
              useProgressiveLoading: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看原图 1.0 MB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(client.requestedUrls, [originalUrl]);
    final filesAfter = temporaryDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('sylulive_original_'))
        .map((file) => file.path)
        .toSet();
    final createdFiles = filesAfter.difference(filesBefore).toList();
    expect(
      createdFiles.any((path) => path.endsWith('.jpg')),
      isTrue,
      reason: '下载完成后应留下正式文件，实际新增文件：$createdFiles',
    );
    expect(
      createdFiles.any((path) => path.endsWith('.part')),
      isFalse,
      reason: '流程结束后不应留下 .part，实际新增文件：$createdFiles',
    );
    expect(tester.takeException(), isNull);
  });
}
