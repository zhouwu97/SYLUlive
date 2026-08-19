import 'dart:typed_data';

import 'package:file/file.dart' as pkg_file;
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/utils/private_message_media_cache.dart';

class _FakeMemoryCacheManager extends Fake implements CacheManager {
  final Map<String, FileInfo> _store = {};
  final MemoryFileSystem _fs = MemoryFileSystem();
  int emptyCacheCallCount = 0;

  @override
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false}) async {
    return _store[key];
  }

  @override
  Future<pkg_file.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final cacheKey = key ?? url;
    final file = _fs.file('/tmp/$cacheKey.$fileExtension')..createSync(recursive: true);
    file.writeAsBytesSync(fileBytes);
    final info = FileInfo(
      file,
      FileSource.Online,
      DateTime.now().add(maxAge),
      url,
    );
    _store[cacheKey] = info;
    return file;
  }

  @override
  Future<void> emptyCache() async {
    emptyCacheCallCount++;
    _store.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrivateMessageMediaCache', () {
    late _FakeMemoryCacheManager fakeManager;

    setUp(() {
      fakeManager = _FakeMemoryCacheManager();
      PrivateMessageMediaCache.instance.customManager = fakeManager;
    });

    tearDown(() {
      PrivateMessageMediaCache.instance.scopeByAccount(null);
      PrivateMessageMediaCache.instance.customManager = null;
    });

    test('cacheKeyFor scopes by account and rejects tokens', () {
      const url = 'https://example.com/api/messages/files/100';

      final keyA = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 1);
      final keyB = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 2);
      final keyAnon = PrivateMessageMediaCache.cacheKeyFor(url, accountId: null);

      expect(keyA, equals('pm:1:$url'));
      expect(keyB, equals('pm:2:$url'));
      expect(keyAnon, equals('pm:anon:$url'));
      expect(keyA, isNot(equals(keyB)));

      // 绝不包含 Bearer 或敏感 Token 字符串
      expect(keyA.toLowerCase(), isNot(contains('bearer')));
      expect(keyA.toLowerCase(), isNot(contains('authorization')));
      expect(keyA.toLowerCase(), isNot(contains('token')));
    });

    test('security regression: account A private media cannot leak to account B even without cleanup', () async {
      const url = 'https://example.com/api/messages/files/secret_image_100';

      // 账号 A 写入私有媒体
      final keyA = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 101);
      await fakeManager.putFile(
        url,
        Uint8List.fromList([1, 2, 3, 4]),
        key: keyA,
      );

      // 确认账号 A 能读取自身缓存
      final cachedA = await fakeManager.getFileFromCache(keyA);
      expect(cachedA, isNotNull);

      // 账号 B 使用相同 URL 查询
      final keyB = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 102);

      // 即使此时 cleanup 故意没有执行，账号 B 查询自身 key 依然为 null
      final cachedB = await fakeManager.getFileFromCache(keyB);
      expect(cachedB, isNull);
    });

    test('security regression: late-arriving network response from old account cannot be read by new account', () async {
      const url = 'https://example.com/api/messages/files/slow_image_200';

      // 模拟账号 1 发起请求后切换到账号 2
      PrivateMessageMediaCache.instance.scopeByAccount(2);

      // 账号 1 的慢速 HTTP 请求晚到并写入磁盘 (带有账号 1 的 key)
      final keyA = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 1);
      await fakeManager.putFile(
        url,
        Uint8List.fromList([9, 9, 9]),
        key: keyA,
      );

      // 账号 2 在当前活跃会话中查询
      final keyCurrent = PrivateMessageMediaCache.cacheKeyFor(url);
      expect(keyCurrent, equals('pm:2:$url'));

      final cachedCurrent = await fakeManager.getFileFromCache(keyCurrent);
      expect(cachedCurrent, isNull);
    });

    test('scopeByAccount updates active account and triggers cache clearance', () async {
      const url = 'https://example.com/api/messages/files/1';
      final key1 = PrivateMessageMediaCache.cacheKeyFor(url, accountId: 1);
      await fakeManager.putFile(url, Uint8List.fromList([1]), key: key1);

      PrivateMessageMediaCache.instance.scopeByAccount(1);
      expect(PrivateMessageMediaCache.instance.accountId, equals(1));
      expect(PrivateMessageMediaCache.cacheKeyFor(url), equals('pm:1:$url'));

      // 切换到账号 2 触发清空
      PrivateMessageMediaCache.instance.scopeByAccount(2);
      expect(PrivateMessageMediaCache.instance.accountId, equals(2));
      expect(PrivateMessageMediaCache.cacheKeyFor(url), equals('pm:2:$url'));

      // 等待异步清空触发
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fakeManager.emptyCacheCallCount, greaterThanOrEqualTo(1));
      expect(await fakeManager.getFileFromCache(key1), isNull);
    });

    test('clearAll is idempotent and safe against repeated calls', () async {
      await PrivateMessageMediaCache.instance.clearAll();
      await PrivateMessageMediaCache.instance.clearAll();
      expect(fakeManager.emptyCacheCallCount, equals(2));
    });

    test('AccountSessionCleanupCoordinator triggers clearAll without requiring user in context', () async {
      final initialCount = fakeManager.emptyCacheCallCount;
      await AccountSessionCleanupCoordinator.instance.closeCurrentSession();
      expect(fakeManager.emptyCacheCallCount, equals(initialCount + 1));
    });
  });
}
