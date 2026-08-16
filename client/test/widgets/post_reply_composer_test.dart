import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';

Widget _buildComposer({
  required PostReplyComposerController controller,
  bool enabled = true,
  bool sending = false,
  ThemeData? theme,
  double textScaleFactor = 1,
  VoidCallback? onNeedLogin,
  PostReplySubmitCallback? onSubmit,
  PostReplyImagePicker? pickImage,
}) {
  return MaterialApp(
    theme: theme,
    builder: (context, child) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScaleFactor),
        ),
        child: child!,
      );
    },
    home: Scaffold(
      body: Column(
        children: [
          const Spacer(),
          PostReplyComposer(
            controller: controller,
            sending: sending,
            enabled: enabled,
            onSubmit: onSubmit ?? (_) async => true,
            onNeedLogin: onNeedLogin ?? () {},
            pickImage: pickImage,
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('评论栏默认完整显示但不自动聚焦', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_buildComposer(controller: controller));

    expect(find.byKey(const ValueKey('post-reply-composer')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-image-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-reply-input')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-emoji-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-send-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-collapsed-input')), findsNothing);
    expect(controller.focusNode.hasFocus, isFalse);

    expect(
      tester.getSize(find.byKey(const ValueKey('post-reply-image-button'))),
      const Size(44, 44),
    );
    expect(
      tester.getSize(
          find.byKey(const ValueKey('post-reply-send-button-container'))),
      const Size(44, 44),
    );
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('post-reply-send-button')),
    );
    expect(sendButton.onPressed, isNull);
  });

  testWidgets('点击输入框后获得焦点', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_buildComposer(controller: controller));

    await tester.tap(find.byKey(const ValueKey('post-reply-input')));
    await tester.pump();

    expect(controller.focusNode.hasFocus, isTrue);
    expect(controller.isOpen, isTrue);
  });

  testWidgets('深色模式与大字体下完整评论栏不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _buildComposer(
        controller: controller,
        theme: ThemeData.dark(),
        textScaleFactor: 1.5,
      ),
    );
    await tester.pump();

    expect(
        find.byKey(const ValueKey('post-reply-image-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-reply-input')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-emoji-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-send-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录时输入、图片和表情入口触发登录回调', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    var loginRequests = 0;

    await tester.pumpWidget(
      _buildComposer(
        controller: controller,
        enabled: false,
        onNeedLogin: () => loginRequests++,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('post-reply-input')));
    await tester.tap(find.byKey(const ValueKey('post-reply-image-button')));
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();

    expect(loginRequests, 3);
    expect(controller.focusNode.hasFocus, isFalse);
    expect(controller.showEmojiPanel, isFalse);
    expect(find.byKey(const ValueKey('post-reply-input')), findsOneWidget);
  });

  testWidgets('发送成功后清空回复对象并保持完整评论栏', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    PostReplyDraft? submitted;

    await tester.pumpWidget(
      _buildComposer(
        controller: controller,
        onSubmit: (draft) async {
          submitted = draft;
          return true;
        },
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
    expect(controller.focusNode.hasFocus, isFalse);
    expect(find.byKey(const ValueKey('post-reply-input')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-image-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-emoji-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-send-button')), findsOneWidget);
  });

  testWidgets('本地图片可选择、预览并作为草稿发送', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    final image = XFile('reply-image.jpg');
    PostReplyDraft? submitted;

    await tester.pumpWidget(
      _buildComposer(
        controller: controller,
        pickImage: () async => image,
        onSubmit: (draft) async {
          submitted = draft;
          return true;
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('post-reply-image-button')));
    await tester.pumpAndSettle();

    expect(controller.localImage?.name, 'reply-image.jpg');
    expect(
      find.byKey(const ValueKey('local-image-composer-preview')),
      findsOneWidget,
    );
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('post-reply-send-button')),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('post-reply-send-button')));
    await tester.pumpAndSettle();

    expect(submitted?.localImage?.name, 'reply-image.jpg');
    expect(controller.localImage, isNull);
    expect(
      find.byKey(const ValueKey('local-image-composer-preview')),
      findsNothing,
    );
  });

  testWidgets('发送失败时保留文字与图片草稿供重试', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);
    final image = XFile('retry.jpg');

    await tester.pumpWidget(
      _buildComposer(
        controller: controller,
        pickImage: () async => image,
        onSubmit: (_) async => false,
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('post-reply-input')),
      '稍后重试',
    );
    await tester.tap(find.byKey(const ValueKey('post-reply-image-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-reply-send-button')));
    await tester.pumpAndSettle();

    expect(controller.textController.text, '稍后重试');
    expect(controller.localImage?.name, 'retry.jpg');
    expect(
      find.byKey(const ValueKey('local-image-composer-preview')),
      findsOneWidget,
    );
  });
}
