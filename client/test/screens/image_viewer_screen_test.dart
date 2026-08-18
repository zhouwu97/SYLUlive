import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as pkg_file;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/utils/private_message_media_cache.dart';

class _TrackingFakeCacheManager extends Fake implements BaseCacheManager {
  final Map<String, FileInfo> store = {};
  final List<String> requestedKeys = [];
  final MemoryFileSystem fs = MemoryFileSystem();

  @override
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false}) async {
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
        if (call.method == 'putImage') {
          return null;
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

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.httpHeaders, {'Authorization': 'Bearer viewer-token'});
    expect(image.cacheManager, equals(fakePrivateCache));
    expect(image.cacheKey, equals('pm:42:$testUrl'));
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
}
