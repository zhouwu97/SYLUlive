import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';

Reply buildLikeTestReply({
  int id = 1,
  int likeCount = 12,
  bool isLiked = false,
}) {
  return Reply(
    id: id,
    postId: 1,
    authorId: 1,
    content: '测试评论内容',
    status: 'normal',
    likeCount: likeCount,
    isLiked: isLiked,
    createdAt: DateTime(2026, 8, 1),
  );
}

Future<void> pumpReplyItem(
  WidgetTester tester, {
  required Reply reply,
  VoidCallback? onLike,
  bool likePending = false,
  VoidCallback? onReply,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF6B8EFF)),
      home: Scaffold(
        body: PostReplyItem(
          reply: reply,
          onReply: onReply ?? () {},
          onLike: onLike,
          likePending: likePending,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('isLiked=false 显示 favorite_border', (tester) async {
    await pumpReplyItem(tester, reply: buildLikeTestReply(), onLike: () {});
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('isLiked=true 显示 favorite', (tester) async {
    await pumpReplyItem(
      tester,
      reply: buildLikeTestReply(isLiked: true),
      onLike: () {},
    );
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('likeCount=12 显示 12', (tester) async {
    await pumpReplyItem(tester, reply: buildLikeTestReply(likeCount: 12), onLike: () {});
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('点击 like 触发 onLike 一次', (tester) async {
    var likeCalls = 0;
    await pumpReplyItem(
      tester,
      reply: buildLikeTestReply(),
      onLike: () => likeCalls++,
    );
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    expect(likeCalls, 1);
  });

  testWidgets('pending 时点击不触发 onLike（防连点）', (tester) async {
    var likeCalls = 0;
    await pumpReplyItem(
      tester,
      reply: buildLikeTestReply(),
      onLike: () => likeCalls++,
      likePending: true,
    );
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    expect(likeCalls, 0);
  });

  testWidgets('点 like 不触发 onReply（防止弹出输入框）', (tester) async {
    var replyCalls = 0;
    await pumpReplyItem(
      tester,
      reply: buildLikeTestReply(),
      onReply: () => replyCalls++,
      onLike: () {},
    );
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    expect(replyCalls, 0);
  });

  testWidgets('点回复区域仍触发 onReply', (tester) async {
    var replyCalls = 0;
    await pumpReplyItem(
      tester,
      reply: buildLikeTestReply(),
      onReply: () => replyCalls++,
      onLike: () {},
    );
    await tester.tap(find.text('测试评论内容'));
    await tester.pump();
    expect(replyCalls, 1);
  });

  testWidgets('onLike 为 null 时不渲染点赞按钮', (tester) async {
    await pumpReplyItem(tester, reply: buildLikeTestReply());
    // 不传 onLike → 无点赞图标
    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });
}
