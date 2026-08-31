import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  @override
  User? get user => null;
}

PostImage _image({
  required String thumbUrl,
  int size = 1024,
  Map<String, String> variantStatus = const {},
}) {
  return PostImage(
    id: 1,
    postId: 1,
    fileId: 1,
    file: FileItem(
      id: 1,
      hash: 'hash',
      path: '/uploads/ab/hash.jpg',
      size: size,
      mimeType: 'image/jpeg',
      width: 4000,
      height: 3000,
    ),
    thumbUrl: thumbUrl,
    mediumUrl: thumbUrl,
    variantStatus: variantStatus,
  );
}

Widget _host(Post post) {
  return ChangeNotifierProvider<AuthProvider>(
    create: (_) => _FakeAuthProvider(),
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: MarketPostCard(post: post)),
    ),
  );
}

Post _post(List<PostImage> images) {
  return Post(
    id: 1,
    title: '显示器',
    content: '成色很好',
    boardId: 2,
    authorId: 1,
    postType: 'sell',
    price: 99,
    images: images,
    createdAt: DateTime(2026, 7, 3),
  );
}

void main() {
  testWidgets('封面使用 thumb 变体，避免列表加载原图', (tester) async {
    await tester.pumpWidget(
      _host(_post([_image(thumbUrl: '/uploads/ab/hash_v1_thumb.jpg')])),
    );

    final images = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .toList();
    expect(images, isNotEmpty);
    expect(
      images.any((image) => image.imageUrl.endsWith('_v1_thumb.jpg')),
      isTrue,
    );
  });

  testWidgets('变体未就绪时封面回退原图，不出现空图', (tester) async {
    await tester.pumpWidget(_host(_post([_image(thumbUrl: '')])));

    final images = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .toList();
    expect(images, isNotEmpty);
    expect(
      images.any((image) => image.imageUrl.endsWith('/uploads/ab/hash.jpg')),
      isTrue,
    );
  });

  testWidgets('大图变体 pending/failed 时封面保持骨架，不请求原图', (tester) async {
    await tester.pumpWidget(
      _host(
        _post([
          _image(
            thumbUrl: '',
            size: 4 * 1024 * 1024,
            variantStatus: const {
              'thumb': 'pending',
              'medium': 'failed',
              'viewer': 'pending',
            },
          ),
        ]),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('商品卡片进入查看器时保留原图大小策略', (tester) async {
    await tester.pumpWidget(
      _host(_post([_image(thumbUrl: '/uploads/ab/hash_v1_thumb.jpg')])),
    );

    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pumpAndSettle();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('viewer-original-image-0')),
      findsOneWidget,
    );
    expect(find.textContaining('查看原图'), findsNothing);
  });
}
