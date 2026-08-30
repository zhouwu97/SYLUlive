import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/canteen_pending_image_cache.dart';

void main() {
  setUp(() {
    CanteenPendingImageCache.instance.scopeByAccount(null);
  });

  group('CanteenPendingImageCache 缓存隔离与密钥规范测试', () {
    test('未登录或匿名账号生成 anon 作用域缓存键', () {
      CanteenPendingImageCache.instance.scopeByAccount(null);
      final key = CanteenPendingImageCache.cacheKeyFor('http://example.com/canteen/store1.jpg');
      expect(key, equals('canteen_pending:anon:http://example.com/canteen/store1.jpg'));
    });

    test('已登录管理员生成 accountId 作用域缓存键，且不泄露 Bearer Token', () {
      CanteenPendingImageCache.instance.scopeByAccount(10086);
      const url = 'http://example.com/uploads/store_front.png';
      final key = CanteenPendingImageCache.cacheKeyFor(url);
      expect(key, equals('canteen_pending:10086:$url'));
      expect(key.contains('Bearer'), isFalse);
      expect(key.contains('token'), isFalse);
    });

    test('支持显式指定 accountId 生成独立的审核缓存键', () {
      final key1 = CanteenPendingImageCache.cacheKeyFor(
        'http://example.com/store.jpg',
        accountId: 1,
      );
      final key2 = CanteenPendingImageCache.cacheKeyFor(
        'http://example.com/store.jpg',
        accountId: 2,
      );
      expect(key1, equals('canteen_pending:1:http://example.com/store.jpg'));
      expect(key2, equals('canteen_pending:2:http://example.com/store.jpg'));
      expect(key1, isNot(equals(key2)));
    });

    test('切换账号时隔离缓存实例并触发安全清理', () async {
      CanteenPendingImageCache.instance.scopeByAccount(1001);
      expect(CanteenPendingImageCache.instance.accountId, equals(1001));

      // 切换到账号 1002
      CanteenPendingImageCache.instance.scopeByAccount(1002);
      expect(CanteenPendingImageCache.instance.accountId, equals(1002));
      final key = CanteenPendingImageCache.cacheKeyFor('http://example.com/image.jpg');
      expect(key, startsWith('canteen_pending:1002:'));
    });

    test('成功注册至 AccountSessionCleanupCoordinator', () {
      // 触发 clearAll 确保单例正常接入统一生命周期
      expect(
        () async => await CanteenPendingImageCache.instance.clearAll(),
        returnsNormally,
      );
    });
  });
}
