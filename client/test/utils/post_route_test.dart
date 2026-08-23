import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/utils/post_route.dart';

void main() {
  testWidgets('集市帖子未显式指定布局时仍进入集市详情', (tester) async {
    final marketPost = Post(
      id: 42,
      content: '待出售的商品',
      boardId: 2,
      authorId: 7,
      postType: 'sell',
      createdAt: DateTime(2026, 8, 23),
    );
    late Widget routedWidget;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final route = buildPostDetailRoute(marketPost);
            routedWidget = (route as MaterialPageRoute<void>).builder(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(routedWidget, isA<PostDetailScreen>());
    expect((routedWidget as PostDetailScreen).isMarket, isTrue);
  });
}
