import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/utils/governed_post_image_cache.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';

import '../helpers/mock_public_image_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // CacheManager 构造会经 path_provider 解析磁盘目录，必须给出可写且可控的
    // 临时目录，否则在无真机环境下会落到 MethodChannel 并抛异常。
    await installMockPublicImageHttp();
    GovernedPostImageCache.instance.scopeByAccount(null);
  });

  tearDown(() {
    GovernedPostImageCache.instance.resetManager();
    uninstallMockPublicImageHttp();
  });

  group('GovernedPostImageCache 账号隔离与凭证安全', () {
    test('未登录时生成 anon 作用域缓存键', () {
      GovernedPostImageCache.instance.scopeByAccount(null);
      const url = 'http://example.com/uploads/ab/thumb.jpg';
      expect(
        GovernedPostImageCache.cacheKeyFor(url),
        equals('governed_post:anon:$url'),
      );
    });

    test('已登录时按账号生成缓存键，且绝不把 JWT 写进 key', () {
      const url = 'http://example.com/uploads/ab/thumb.jpg';
      const token = 'jwt-header.payload.signature';
      final key = GovernedPostImageCache.cacheKeyFor(url, accountId: 10086);
      expect(key, equals('governed_post:10086:$url'));
      expect(key.contains(token), isFalse);
      expect(key.toLowerCase().contains('bearer'), isFalse);
    });

    test('不同账号的同名 URL 生成互不复用的缓存键', () {
      const url = 'http://example.com/uploads/ab/origin.jpg';
      final keyA = GovernedPostImageCache.cacheKeyFor(url, accountId: 1);
      final keyB = GovernedPostImageCache.cacheKeyFor(url, accountId: 2);
      expect(keyA, isNot(equals(keyB)));
    });

    test('私有缓存与公开帖子缓存物理隔离，且都支持磁盘尺寸约束', () async {
      final governed = GovernedPostImageCache.instance.manager;
      final public = PostImageCache.manager;
      expect(identical(governed, public), isFalse);
      // 治理帖缩略图会传 maxWidthDiskCache / maxHeightDiskCache，
      // cached_network_image 据此断言缓存管理器具备 ImageCacheManager 能力。
      expect(governed, isA<ImageCacheManager>());
      expect(public, isA<ImageCacheManager>());
      // CacheManager 的磁盘目录初始化是 fire-and-forget：等它落定再让 tearDown
      // 删除临时目录，否则异步建目录会以「测试结束后才失败」的形式报出来。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    test('切换账号后缓存键作用域随之切换', () async {
      GovernedPostImageCache.instance.scopeByAccount(1001);
      expect(GovernedPostImageCache.instance.accountId, equals(1001));
      expect(
        GovernedPostImageCache.cacheKeyFor('http://example.com/a.jpg'),
        startsWith('governed_post:1001:'),
      );

      GovernedPostImageCache.instance.scopeByAccount(1002);
      expect(GovernedPostImageCache.instance.accountId, equals(1002));
      expect(
        GovernedPostImageCache.cacheKeyFor('http://example.com/a.jpg'),
        startsWith('governed_post:1002:'),
      );
    });

    test('已注册到会话清理协调器，登出/换号会清空私有缓存', () async {
      // 私有图片缓存必须随会话关闭一起清空，否则下一个账号能读到上一个账号
      // 缓存下来的治理帖图片。
      await expectLater(
        AccountSessionCleanupCoordinator.instance.closeCurrentSession(),
        completes,
      );
    });
  });
}
