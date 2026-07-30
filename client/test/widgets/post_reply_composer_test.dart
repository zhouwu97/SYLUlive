import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';

void main() {
  testWidgets('评论栏默认折叠并在一次点击后展开', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              PostReplyComposer(
                controller: controller,
                replyCount: 3,
                likeCount: 5,
                liked: false,
                sending: false,
                enabled: true,
                onToggleLike: () {},
                onSubmit: (_) async => true,
                onNeedLogin: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('post-reply-collapsed-input')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('post-reply-input')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('post-reply-collapsed-input')),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('post-reply-input')), findsOneWidget);
    expect(controller.focusNode.hasFocus, isTrue);
  });

  testWidgets('未登录点击评论入口只触发登录回调', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    var loginRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              PostReplyComposer(
                controller: controller,
                replyCount: 0,
                likeCount: 0,
                liked: false,
                sending: false,
                enabled: false,
                onToggleLike: () {},
                onSubmit: (_) async => true,
                onNeedLogin: () => loginRequests++,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('post-reply-collapsed-input')),
    );
    await tester.pump();

    expect(loginRequests, 1);
    expect(controller.isOpen, isFalse);
    expect(find.byKey(const ValueKey('post-reply-input')), findsNothing);
  });

  testWidgets('发送成功后折叠并清空回复对象', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    PostReplyDraft? submitted;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              PostReplyComposer(
                controller: controller,
                replyCount: 1,
                likeCount: 2,
                liked: true,
                sending: false,
                enabled: true,
                onToggleLike: () {},
                onSubmit: (draft) async {
                  submitted = draft;
                  return true;
                },
                onNeedLogin: () {},
              ),
            ],
          ),
        ),
      ),
    );

    controller.openReply(
      parentReplyId: 9,
      replyToUserId: 12,
      replyToName: '同学',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('post-reply-input')),
      '@同学 收到',
    );
    await tester.tap(find.byKey(const ValueKey('post-reply-send-button')));
    await tester.pumpAndSettle();

    expect(submitted?.parentReplyId, 9);
    expect(submitted?.replyToUserId, 12);
    expect(controller.isOpen, isFalse);
    expect(controller.textController.text, isEmpty);
    expect(controller.parentReplyId, isNull);
  });
}
