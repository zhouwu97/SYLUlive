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
  bool disableAnimations = false,
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
          disableAnimations: disableAnimations,
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

  testWidgets('回复某人时显示回复上下文条且不污染输入框文本，可取消或发送', (tester) async {
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
      replyToName: '纯合子',
    );
    await tester.pump();

    // 输入框不应被塞入 @纯合子
    expect(controller.textController.text, isEmpty);
    expect(find.byKey(const ValueKey('post-reply-target-banner')), findsOneWidget);
    expect(find.text('回复 纯合子'), findsOneWidget);

    // 输入回复内容并发送
    await tester.enterText(
      find.byKey(const ValueKey('post-reply-input')),
      '收到攻略',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-reply-send-button')));
    await tester.pumpAndSettle();

    expect(submitted?.parentReplyId, 9);
    expect(submitted?.replyToUserId, 12);
    expect(submitted?.replyToName, '纯合子');
    expect(submitted?.text, '收到攻略');
    expect(controller.isOpen, isFalse);
    expect(controller.textController.text, isEmpty);
    expect(controller.parentReplyId, isNull);
    expect(find.byKey(const ValueKey('post-reply-target-banner')), findsNothing);
  });

  testWidgets('点击取消回复按钮退出回复上下文', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_buildComposer(controller: controller));

    controller.openReply(
      parentReplyId: 9,
      replyToUserId: 12,
      replyToName: '纯合子',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('post-reply-target-banner')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('post-reply-cancel-target-button')));
    await tester.pump();

    expect(find.byKey(const ValueKey('post-reply-target-banner')), findsNothing);
    expect(controller.parentReplyId, isNull);
    expect(controller.replyToName, isNull);
  });

  testWidgets('表情面板切换与返回键拦截', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_buildComposer(controller: controller));

    // 打开表情面板
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();

    expect(controller.showEmojiPanel, isTrue);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
    expect(find.byKey(const ValueKey('post-reply-emoji-panel')), findsOneWidget);

    // 再次点击表情按钮：进入 Emoji → Keyboard 交接，Emoji 保持原位，
    // 直到 IME 覆盖 90%（测试环境无 IME，依赖 400ms 保险超时完成交接）
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();

    expect(controller.inputHandoffActive, isTrue);
    expect(controller.showEmojiPanel, isTrue);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);

    await tester.pump(const Duration(milliseconds: 450));
    expect(controller.inputHandoffActive, isFalse);
    expect(controller.showEmojiPanel, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);
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

  test('键盘 inset 逐帧驱动面板：>0 进入 keyboard，归零后才切 none', () {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    expect(controller.bottomPanel, PostReplyBottomPanel.none);
    controller.updateKeyboardMetrics(120);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);
    controller.updateKeyboardMetrics(240);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);
    controller.updateKeyboardMetrics(356);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);
    // 键盘收起过程中（inset 尚未归零）panel 保持 keyboard，
    // 不允许瞬间切 none 造成页面下落
    controller.updateKeyboardMetrics(180);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);
    controller.updateKeyboardMetrics(0);
    expect(controller.bottomPanel, PostReplyBottomPanel.none);
  });

  test('Emoji → Keyboard：覆盖 90% 即完成交接，无 100ms settle 等待', () {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    controller.toggleEmojiPanel(keyboardInset: 356);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
    expect(controller.stableKeyboardHeight, 356);

    controller.toggleEmojiPanel(); // 发起交接
    expect(controller.inputHandoffActive, isTrue);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);

    // 首帧小 inset 不能改写交接基准（fresh page 防坍塌）
    controller.updateKeyboardMetrics(40);
    expect(controller.inputHandoffActive, isTrue);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
    // 未到 90%（356 * 0.9 = 320.4）：继续等待，不依赖定时器
    controller.updateKeyboardMetrics(300);
    expect(controller.inputHandoffActive, isTrue);
    // 覆盖 90% 后立即完成，无 100ms settle
    controller.updateKeyboardMetrics(321);
    expect(controller.inputHandoffActive, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);

    // 键盘未起来的异常场景：取消交接并保持 Emoji
    controller.toggleEmojiPanel(keyboardInset: 356);
    controller.toggleEmojiPanel();
    controller.updateKeyboardMetrics(0);
    expect(controller.inputHandoffActive, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
  });

  test('连续快速 Emoji/Keyboard 切换不残留 handoff', () {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    controller.toggleEmojiPanel(keyboardInset: 356); // Emoji
    controller.toggleEmojiPanel(); // handoff #1
    controller.toggleEmojiPanel(); // 快速重按：handoff #2（generation 递增）
    expect(controller.inputHandoffActive, isTrue);
    controller.updateKeyboardMetrics(321); // 覆盖 90% 完成
    expect(controller.inputHandoffActive, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.keyboard);

    controller.toggleEmojiPanel(keyboardInset: 356); // 再回 Emoji
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
    controller.toggleEmojiPanel(); // 再发起交接
    controller.updateKeyboardMetrics(0); // 键盘没起来 → 取消
    expect(controller.inputHandoffActive, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.emoji);
  });

  testWidgets('系统返回键关闭表情面板', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_buildComposer(controller: controller));
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();
    expect(controller.showEmojiPanel, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(controller.showEmojiPanel, isFalse);
    expect(controller.bottomPanel, PostReplyBottomPanel.none);
  });

  testWidgets('disableAnimations 时表情面板高度动画立即完成', (tester) async {
    final controller = PostReplyComposerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _buildComposer(controller: controller, disableAnimations: true),
    );
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump(); // 单帧即到位，不做 160ms 高度动画

    expect(controller.showEmojiPanel, isTrue);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('post-reply-emoji-panel-container')),
          )
          .height,
      300,
    );
  });

  testWidgets('dispose 时 handoff timer 被取消，不触发已释放通知', (tester) async {
    final controller = PostReplyComposerController();

    await tester.pumpWidget(_buildComposer(controller: controller));
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-reply-emoji-button')));
    await tester.pump();
    expect(controller.inputHandoffActive, isTrue);

    // 先卸载组件再释放 controller；400ms timer 必须被取消
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
}
