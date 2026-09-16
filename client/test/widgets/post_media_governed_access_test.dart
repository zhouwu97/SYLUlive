import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/utils/governed_post_image_cache.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';
import 'package:shenliyuan/utils/post_media_access.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

/// 只给原图，避免进度式缩略图底座产生第二个 CachedNetworkImage 干扰断言。
List<PostImage> _originOnlyImage() => [
      PostImage(
        id: 1,
        postId: 1,
        fileId: 1,
        originUrl: '/uploads/ab/governed.jpg',
      ),
    ];

Widget _host(PostMediaAccess access) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: PostMediaView(
            images: _originOnlyImage(),
            variant: PostMediaVariant.detail,
            access: access,
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    GovernedPostImageCache.instance.scopeByAccount(null);
  });

  tearDown(() {
    // 缓存管理器绑定创建时的磁盘目录，测试结束后重建，避免污染后续用例。
    GovernedPostImageCache.instance.resetManager();
  });

  group('PostMediaAccess 凭证语义', () {
    test('公开模式不带认证头，缓存键保持原 URL', () {
      const access = PostMediaAccess.public();
      expect(access.isAuthorized, isFalse);
      expect(access.httpHeaders, isEmpty);
      expect(access.cacheKeyFor('http://example.com/a.jpg'),
          equals('http://example.com/a.jpg'));
    });

    test('鉴权模式携带 Bearer JWT 并使用账号作用域缓存键', () {
      const access =
          PostMediaAccess.authorized(token: 'jwt-token-abc', accountId: 42);
      expect(access.isAuthorized, isTrue);
      expect(access.httpHeaders,
          equals({'Authorization': 'Bearer jwt-token-abc'}));
      expect(
        access.cacheKeyFor('http://example.com/a.jpg'),
        equals('governed_post:42:http://example.com/a.jpg'),
      );
    });

    test('空 token 不产生认证头，避免发出无效的 Authorization 请求', () {
      const access = PostMediaAccess.authorized(token: '   ', accountId: 1);
      expect(access.httpHeaders, isEmpty);
    });

    test('凭证参与相等比较：账号切换会触发图片重新解析', () {
      const a = PostMediaAccess.authorized(token: 't1', accountId: 1);
      const b = PostMediaAccess.authorized(token: 't2', accountId: 1);
      expect(a == b, isFalse);
      expect(a == const PostMediaAccess.authorized(token: 't1', accountId: 1),
          isTrue);
    });
  });

  group('PostMediaView 治理帖图片走鉴权私有通道', () {
    testWidgets('公开模式沿用公开帖子缓存，不带认证头与自定义缓存键', (tester) async {
      await tester.pumpWidget(_host(const PostMediaAccess.public()));

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.cacheManager, same(PostImageCache.manager));
      expect(image.httpHeaders, isNull);
      expect(image.cacheKey, isNull);
    });

    testWidgets('鉴权模式切换到账号隔离私有缓存并携带 Bearer JWT', (tester) async {
      await tester.pumpWidget(
        _host(
          const PostMediaAccess.authorized(
            token: 'jwt-token-abc',
            accountId: 42,
          ),
        ),
      );

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      // 核心断言：不能复用公开帖子缓存，否则治理帖图片会命中被降权前的公开副本，
      // 或者反过来把私有响应写进公开缓存。
      expect(identical(image.cacheManager, PostImageCache.manager), isFalse);
      expect(image.cacheManager, same(GovernedPostImageCache.instance.manager));
      expect(image.httpHeaders,
          equals({'Authorization': 'Bearer jwt-token-abc'}));
      expect(
        image.cacheKey,
        equals(
          GovernedPostImageCache.cacheKeyFor(image.imageUrl, accountId: 42),
        ),
      );
      expect(image.cacheKey!.contains('jwt-token-abc'), isFalse);
    });
  });
}
