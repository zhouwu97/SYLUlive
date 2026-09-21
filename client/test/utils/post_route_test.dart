import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
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

  testWidgets('置顶投票仍进入投票详情而不是普通帖子详情', (tester) async {
    final pollPost = Post.fromJson({
      'id': 43,
      'title': '投票主题',
      'content': '投票说明',
      'board_id': 1,
      'author_id': 7,
      'content_kind': 'poll',
      'created_at': '2026-08-23T00:00:00Z',
      'poll_meta': {
        'id': 99,
        'post_id': 43,
        'selection_mode': 'single',
        'max_choices': 1,
        'ends_at': '2026-08-24T00:00:00Z',
        'options': [
          {'id': 1, 'text': '选项一', 'sort_order': 0},
        ],
      },
    });
    late Widget routedWidget;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final route = buildPostDetailRoute(pollPost);
            routedWidget = (route as MaterialPageRoute<void>).builder(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(routedWidget, isA<PollDetailScreen>());
    expect((routedWidget as PollDetailScreen).pollId, 99);
  });
}
