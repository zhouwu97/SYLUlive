import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';

void main() {
  testWidgets('楼中楼外层摘要用图片占位文字', (tester) async {
    final root = Reply(
      id: 1,
      postId: 100,
      authorId: 1,
      content: '根评论',
      createdAt: DateTime(2026, 9, 24),
    );
    final child = Reply(
      id: 2,
      postId: 100,
      parentReplyId: root.id,
      authorId: 2,
      content: '带图片的楼中楼回复',
      createdAt: DateTime(2026, 9, 24),
      images: [
        ReplyImage(
          id: 20,
          replyId: 2,
          fileId: 30,
          thumbUrl: '/uploads/reply-thumb.jpg',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostReplyList(
            replies: [root, child],
            onReply: (_) {},
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('带图片的楼中楼回复') &&
            widget.text.toPlainText().contains('[图片]'),
      ),
      findsOneWidget,
    );
  });
}
