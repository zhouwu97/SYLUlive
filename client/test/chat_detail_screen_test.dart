import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/chat_detail_screen.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import 'package:shenliyuan/widgets/emoji/sticker_composer_preview.dart';

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  _FakeAuthProvider(this.currentUser);

  final User currentUser;

  @override
  User get user => currentUser;

  @override
  String? get token => 'test-token';

  @override
  bool get isLoggedIn => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('empty composer keeps send visible and text enables it',
      (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    final disabledSendButton = _sendButton(tester);
    final colors = Theme.of(
      tester.element(find.byKey(const ValueKey('chat-send-button'))),
    ).colorScheme;
    expect(disabledSendButton.onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-send-button')),
        matching: find.byIcon(Icons.send_rounded),
      ),
      findsOneWidget,
    );
    expect(
      disabledSendButton.style?.backgroundColor?.resolve(
        {WidgetState.disabled},
      ),
      AppColors.disabledControlLight,
    );
    expect(
      disabledSendButton.style?.foregroundColor?.resolve(
        {WidgetState.disabled},
      ),
      AppColors.disabledControlTextLight,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('chat-send-button')),
        matching: find.byType(AnimatedOpacity),
      ),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    final enabledSendButton = _sendButton(tester);
    expect(enabledSendButton.onPressed, isNotNull);
    expect(
      enabledSendButton.style?.backgroundColor?.resolve({}),
      AppColors.messageOutgoingLight,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('dark composer keeps the disabled send affordance visible',
      (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(
      tester,
      provider,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    );

    final disabledSendButton = _sendButton(tester);
    expect(disabledSendButton.onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-send-button')),
        matching: find.byIcon(Icons.send_rounded),
      ),
      findsOneWidget,
    );
    expect(
      disabledSendButton.style?.backgroundColor?.resolve(
        {WidgetState.disabled},
      ),
      AppColors.disabledControlDark,
    );
    expect(
      disabledSendButton.style?.foregroundColor?.resolve(
        {WidgetState.disabled},
      ),
      AppColors.disabledControlTextDark,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('chat header exposes the profile affordance', (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    expect(find.byKey(const ValueKey('chat-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-header-profile')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-header-more')), findsOneWidget);
    expect(find.text('点击头像查看主页'), findsOneWidget);
    expect(
      tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle
          ?.statusBarIconBrightness,
      Brightness.dark,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-header'))).height,
      64,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('composer controls share one horizontal center line',
      (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    final imageCenter =
        tester.getCenter(find.byKey(const ValueKey('chat-image-button')));
    final inputCenter =
        tester.getCenter(find.byKey(const ValueKey('chat-input-container')));
    final emojiCenter =
        tester.getCenter(find.byKey(const ValueKey('chat-emoji-button')));
    final sendCenter = tester
        .getCenter(find.byKey(const ValueKey('chat-send-button-container')));

    expect(imageCenter.dy, closeTo(inputCenter.dy, 0.01));
    expect(emojiCenter.dy, closeTo(inputCenter.dy, 0.01));
    expect(sendCenter.dy, closeTo(inputCenter.dy, 0.01));
    await _disposeChat(tester, provider);
  });

  testWidgets('composer stays above the bottom system gesture inset',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    // Composer 的 SafeArea 读取 MediaQuery.padding.bottom（保持键盘外的手势区）；
    // 用 view.padding 模拟系统手势区 inset。
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);

    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    expect(
      tester.getRect(find.byKey(const ValueKey('chat-composer'))).bottom,
      closeTo(876, 1),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'first input tap with a 24dp gesture inset does not drop the composer',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final before =
        tester.getRect(find.byKey(const ValueKey('chat-composer'))).bottom;
    expect(find.byKey(const ValueKey('chat-bottom-viewport')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );

    // 点击输入框、IME 尚未产生 viewInsets 的第一帧：Composer 的 bottom 必须
    // 保持原位，不能因 panel 切到 keyboard 而瞬间撤掉系统手势区掉下去。
    await tester.tap(input);
    await tester.pump();

    final after =
        tester.getRect(find.byKey(const ValueKey('chat-composer'))).bottom;
    expect(after, closeTo(before, 0.5));
    expect(after, closeTo(876, 1));
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'keyboard rise frames move the composer monotonically without dipping',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    final composer = find.byKey(const ValueKey('chat-composer'));
    final bottomAtRest = tester.getRect(composer).bottom;

    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();
    // 第一帧（无 IME）：保持原位，不先向下掉。
    expect(
      tester.getRect(composer).bottom,
      closeTo(bottomAtRest, 0.5),
    );

    // 0 → 40 → 120 → 240 → 356：Composer 单调上移，任何一帧都不先向下。
    double previous = tester.getRect(composer).bottom;
    final risingFrames = [0.0, 40.0, 120.0, 240.0, 356.0];
    for (final inset in risingFrames) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      final bottom = tester.getRect(composer).bottom;
      expect(
        bottom,
        lessThanOrEqualTo(previous + 0.5),
        reason: 'composer dipped when IME inset reached $inset',
      );
      previous = bottom;
    }
    expect(previous, lessThan(bottomAtRest - 300));
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'keyboard opened then collapsed reopens cleanly on the next tap',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(
      tester,
      provider,
      theme: ThemeData(
        platform: TargetPlatform.android,
        useMaterial3: true,
      ),
    );

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;

    // 1) 打开键盘
    await tester.tap(input);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // 2) IME 升起再系统收起：旧输入的 Focus 会话必须彻底结束
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);
    tester.view.viewInsets = FakeViewPadding.zero;
    await _pumpFrames(tester, count: 2);
    expect(focusNode.hasFocus, isFalse);

    // 3) 再次点击输入框：一次干净的新输入会话，IME 被重新唤起
    await tester.tap(input);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await _disposeChat(tester, provider);
  });

  testWidgets('dragging further past the latest edge opens the keyboard',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    expect(focusNode.hasFocus, isFalse);

    // reverse 列表 offset 0 即最新消息；继续向最新方向（负向 overscroll）拖动
    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'overscroll at the latest edge does not reopen when drag starts with keyboard open',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(
      tester,
      provider,
      theme: ThemeData(
        platform: TargetPlatform.android,
        useMaterial3: true,
      ),
    );

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;

    // 打开键盘并模拟 IME 可见
    await tester.tap(input);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);
    expect(focusNode.hasFocus, isTrue);

    // 键盘打开时开始拖动到最新边缘：ScrollStart 判定输入面板活跃，
    // 关闭 overscroll→弹键盘 的允许位，同一次手势不得重新弹起键盘。
    final setClientBefore = tester.testTextInput.log
        .where((call) => call.method == 'TextInput.setClient')
        .length;
    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pump();
    final setClientAfter = tester.testTextInput.log
        .where((call) => call.method == 'TextInput.setClient')
        .length;

    // 没有重新建立 IME 会话（未重新弹起键盘）
    expect(setClientAfter, setClientBefore);
    await _disposeChat(tester, provider);
  });

  testWidgets('keyboard closed and dragging down does not open keyboard',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    expect(focusNode.hasFocus, isFalse);

    // 向下拖动 100dp
    await tester.drag(find.byType(ListView).first, const Offset(0, 100));
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await _disposeChat(tester, provider);
  });

  testWidgets('keyboard open and dragging down >= 18dp collapses keyboard',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    await tester.tap(input);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // 向下拖动 60dp (超过 touch slop 后累计达标)
    await tester.drag(find.byType(ListView).first, const Offset(0, 60));
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
    await _disposeChat(tester, provider);
  });

  testWidgets('keyboard open and dragging up does not collapse keyboard',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    await tester.tap(input);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // 向上拖动 50dp
    await tester.drag(find.byType(ListView).first, const Offset(0, -50));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    await _disposeChat(tester, provider);
  });

  testWidgets('emoji open and dragging down message area collapses emoji panel',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Offstage>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('chat-emoji-panel')),
                  matching: find.byType(Offstage),
                )
                .first,
          )
          .offstage,
      isFalse,
    );

    // 在消息列表区域向下拖动 60dp
    await tester.drag(find.byType(ListView).first, const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    expect(find.byKey(const ValueKey('chat-emoji-panel')), findsNothing);
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'keyboard closed and not at latest edge: dragging up only scrolls without opening keyboard',
      (tester) async {
    final provider = MessageProvider(_chatDio(messages: _historyMessages()));
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    expect(focusNode.hasFocus, isFalse);

    // 先向下滚一段距离查看历史（在 reverse 列表中正向 offset 为滚入历史）
    await tester.drag(find.byType(ListView).first, const Offset(0, 300));
    await tester.pump();

    // 此时不在最新消息边缘（pixels > 0），向上拖动（Offset(0, -30)）只回滚消息，不触发键盘
    await tester.drag(find.byType(ListView).first, const Offset(0, -30));
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await _disposeChat(tester, provider);
  });

  testWidgets('single input tap restores the keyboard after composer relayout',
      (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(
      tester,
      provider,
      theme: ThemeData(
        platform: TargetPlatform.android,
        useMaterial3: true,
      ),
    );

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;
    final editableState = tester.state<EditableTextState>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    );
    final clearedClientsBeforeTap = tester.testTextInput.log
        .where((call) => call.method == 'TextInput.clearClient')
        .length;
    expect(focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(input);
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(
      tester.state<EditableTextState>(
        find.descendant(of: input, matching: find.byType(EditableText)),
      ),
      same(editableState),
    );
    expect(
      tester.testTextInput.log
          .where((call) => call.method == 'TextInput.clearClient')
          .length,
      clearedClientsBeforeTap,
    );
    expect(tester.testTextInput.isVisible, isTrue);
    // 键盘未真正弹起前不得预留 stableKeyboardHeight：viewport 跟随真实
    // viewInsets（测试环境无 IME，因此是 0），不能提前撑起 300。
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('keyboard and Emoji panel share the remembered viewport height',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);
    final composerSize =
        tester.getSize(find.byKey(const ValueKey('chat-composer')));

    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);
    final composerTopWithKeyboard =
        tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy;
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy,
      closeTo(composerTopWithKeyboard, 1),
    );

    final stickerGroup = appStickerGroups.first;
    await tester.tap(
      find.byKey(ValueKey('sticker-pack-tab-${stickerGroup.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('sticker-group-${stickerGroup.id}')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy,
      closeTo(composerTopWithKeyboard, 1),
    );

    tester.view.viewInsets = FakeViewPadding.zero;
    await _pumpFrames(tester, count: 2);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    // Emoji → Keyboard 交接期间面板保持原位直到 IME 覆盖；测试环境无 IME，
    // 依赖 750ms 保险超时切回键盘，因此这里推过超时再断言面板关闭。
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(AppEmojiPanel), findsNothing);
    // 交接完成后 viewport 跟随真实 inset（无 IME 时为 0），
    // 内容回到屏幕底部，而不是残留 stableKeyboardHeight 悬空。
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy,
      closeTo(900 - composerSize.height, 1),
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('Emoji panel keeps a 286 pixel keyboard height without clamping',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    tester.view.viewInsets = const FakeViewPadding(bottom: 286);
    await _pumpFrames(tester, count: 2);
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);

    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      286,
    );
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await _disposeChat(tester, provider);
  });

  testWidgets('text sending clears immediately and allows another pending send',
      (tester) async {
    final failureGate = Completer<void>();
    final provider = MessageProvider(_chatDio(failureGate: failureGate));
    await _pumpChat(tester, provider);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '第一条');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chat-input')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(provider.draftFor(3), isEmpty);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '第二条');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();
    expect(provider.messages, hasLength(2));
    expect(provider.messages.every((message) => message.isPending), isTrue);

    failureGate.complete();
    await _pumpFrames(tester);
    await _disposeChat(tester, provider);
  });

  testWidgets('stranger first contact blocks a second outgoing message locally',
      (tester) async {
    final failureGate = Completer<void>();
    final provider = MessageProvider(
      _chatDio(
        failureGate: failureGate,
        sendState: const {
          'can_send': true,
          'first_contact_used': false,
          'target_follows_me': false,
          'target_replied': false,
        },
      ),
    );
    await _pumpChat(tester, provider);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '你好');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();

    expect(provider.messages, hasLength(1));
    expect(find.text('首条私信已提交。等待对方回复后可继续发送。'), findsOneWidget);
    expect(_sendButton(tester).onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-send-button')),
        matching: find.byIcon(Icons.send_rounded),
      ),
      findsOneWidget,
    );

    failureGate.complete();
    await _pumpFrames(tester);
    await _disposeChat(tester, provider);
  });

  testWidgets('optimistic message shows pending then failed retry state',
      (tester) async {
    final failureGate = Completer<void>();
    final provider = MessageProvider(_chatDio(failureGate: failureGate));
    await _pumpChat(tester, provider);

    await tester.enterText(find.byType(TextField), 'send now');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();

    expect(find.text('发送中'), findsOneWidget);
    expect(provider.messages.single.isPending, isTrue);

    failureGate.complete();
    await _pumpFrames(tester);

    expect(find.text('发送失败 · 点击重试'), findsOneWidget);
    expect(provider.messages.single.isFailed, isTrue);
    expect(
      find.byKey(ValueKey('retry-${provider.messages.single.stableKey}')),
      findsOneWidget,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'tapping a sticker sends it immediately without disturbing the draft text',
      (tester) async {
    final failureGate = Completer<void>();
    final provider = MessageProvider(_chatDio(failureGate: failureGate));
    final sticker = appStickerGroups.first.items.first;
    await _pumpChat(tester, provider);

    await tester.enterText(
      find.byKey(const ValueKey('chat-input')),
      '晚安',
    );
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('sticker-pack-tab-${appStickerGroups.first.id}'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('sticker-${sticker.id}')));
    await tester.pump();

    // 点击 sticker 即独立发送，不出现 composer preview，也不清空已输入文字
    expect(find.byType(StickerComposerPreview), findsNothing);
    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.stickerId, sticker.id);
    expect(provider.messages.single.content, isEmpty);
    expect(provider.messages.single.isPending, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chat-input')))
          .controller
          ?.text,
      '晚安',
    );

    failureGate.complete();
    await _pumpFrames(tester);

    expect(provider.messages.single.isFailed, isTrue);
    expect(provider.draftFor(3), '晚安');
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'sticker message with known local sticker ID uses local asset priority',
      (tester) async {
    final sticker = appStickerGroups.first.items.first;
    final provider = MessageProvider(
      _chatDio(messages: [
        {
          'id': 99,
          'conversation_id': 42,
          'sender_id': 3,
          'content': '',
          'sticker_id': sticker.id,
          'file_id': 10,
          'file': {
            'id': 10,
            'hash': 'sticker',
            'path': '/stickers/mingfeng.png',
            'size': 100,
            'mime_type': 'image/png',
          },
          'created_at': '2026-06-14T08:31:00Z',
        },
      ]),
    );
    await _pumpChat(tester, provider);

    expect(
      find.byKey(ValueKey('message-sticker-asset-${sticker.id}')),
      findsOneWidget,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'progressive IME inset transition frames do not shrink Emoji panel height',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    // 1. 打开键盘 356
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);
    final composerTopWithKeyboard =
        tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy;
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    // 2. 点击 Emoji 按钮，切换到表情面板
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);

    // 3. 模拟 Android 真机 IME 收起动画逐帧收缩：310 -> 260 -> 190 -> 100 -> 40 -> 0
    final transitionFrames = [310.0, 260.0, 190.0, 100.0, 40.0, 0.0];
    for (final inset in transitionFrames) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-bottom-viewport')))
            .height,
        356,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy,
        closeTo(composerTopWithKeyboard, 1),
      );
    }
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'progressive IME transition frames from Emoji to keyboard do not jump',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    // 键盘曾为 356
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);

    tester.view.viewInsets = FakeViewPadding.zero;
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);

    // 点击输入框切回键盘
    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();

    // 模拟 Android 真机 IME 逐帧弹起动画：0 -> 50 -> 150 -> 250 -> 356
    final transitionFrames = [0.0, 50.0, 150.0, 250.0, 356.0];
    for (final inset in transitionFrames) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-bottom-viewport')))
            .height,
        356,
      );
    }
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'fresh page with unobserved keyboard height switching from Emoji to keyboard maintains fallback height',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    // 从未弹起过键盘，直接点击 Emoji 按钮（fallback 300）
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    // 自定义 Emoji 面板高度走 160ms Flutter 动画，推完动画再断言
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      300,
    );

    // 点击输入框切回键盘（进入 Emoji → Keyboard 交接）
    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();

    // 模拟 Android 真机 IME 首次逐帧弹起动画：0 -> 40 -> 100 -> 180 -> 260 -> 356
    final transitionFrames = [0.0, 40.0, 100.0, 180.0, 260.0, 356.0];
    for (final inset in transitionFrames) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      // 交接基准是 fallback 300，首帧小 inset 不能改写目标；
      // 高度不能从 300 坍塌到第一帧的 40 或 100
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-bottom-viewport')))
            .height,
        300,
      );
    }
    await _pumpFrames(tester, count: 3);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('系统返回键先关闭输入面板再退出', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    final input = find.byKey(const ValueKey('chat-input'));
    final focusNode = tester.widget<TextField>(input).focusNode!;

    // 键盘态：返回 → unfocus，panel 不瞬切 none，viewport 跟随 inset 逐帧下落
    await tester.tap(input);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
    // 收起过程 inset 尚未归零：viewport 跟随真实 inset（260），不瞬跳 0
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      260,
    );
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );

    // Emoji 态：返回 → 面板直接关闭并回到底部
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _pumpFrames(tester, count: 5); // 等 160ms 高度动画完成
    expect(find.byType(AppEmojiPanel), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      0,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('连续快速 Emoji/Keyboard/Emoji 切换不残留交接状态',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await _pumpFrames(tester, count: 2);

    // Emoji → 快速重按两次（handoff 反复重发，generation 递增）
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pump();

    // 键盘升起，覆盖 90% 后完成交接
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    // 立即再切回 Emoji：面板保持同高
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    // 键盘落下后 Emoji 仍保持稳定高度
    tester.view.viewInsets = FakeViewPadding.zero;
    await _pumpFrames(tester, count: 2);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );

    // 再点回键盘：交接再次完成，无残留 handoff
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 356);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await _pumpFrames(tester, count: 2);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      356,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets('disableAnimations 时 Emoji 面板高度动画立即完成',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider, disableAnimations: true);

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pump(); // 单帧即到位，不做 160ms 高度动画
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      300,
    );
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    await _disposeChat(tester, provider);
  });

  testWidgets('dispose 时 handoff timer 不 setState', (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pump();

    await _disposeChat(tester, provider);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long pressing a message image can add it to favorites',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    EmojiFavoriteService.resetSharedInstanceForTesting();
    addTearDown(EmojiFavoriteService.resetSharedInstanceForTesting);
    const imagePath = '/uploads/chat-favorite.png';
    final provider = MessageProvider(
      _chatDio(messages: [
        {
          'id': 88,
          'conversation_id': 42,
          'sender_id': 3,
          'content': '',
          'file_id': 7,
          'file': {
            'id': 7,
            'hash': 'favorite',
            'path': imagePath,
            'size': 5,
            'mime_type': 'image/png',
          },
          'created_at': '2026-06-14T08:31:00Z',
        },
      ]),
    );
    await _pumpChat(tester, provider);

    await tester.longPress(
      find.byKey(const ValueKey('message-image-server-88')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('收藏'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      await EmojiFavoriteService.instance.containsImage(imagePath),
      isTrue,
    );
    await _disposeChat(tester, provider);
  });

  testWidgets(
      'tapping a GIF favorite sends it immediately with its existing file id',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    EmojiFavoriteService.resetSharedInstanceForTesting();
    addTearDown(EmojiFavoriteService.resetSharedInstanceForTesting);
    final favoriteService = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    await favoriteService.add(
      const EmojiFavoriteItem.custom(
        serverId: 11,
        fileId: 77,
        imageUrl: '/api/emoji/favorites/11/file',
        thumbnailUrl: '/api/emoji/favorites/11/thumbnail',
        mimeType: 'image/gif',
        isAnimated: true,
      ),
    );
    EmojiFavoriteService.configureSharedInstance(favoriteService);

    var uploadRequests = 0;
    Map<String, dynamic>? sentData;
    final provider = MessageProvider(
      _chatDio(
        onUpload: () => uploadRequests++,
        onSend: (data) => sentData = data,
      ),
    );
    await _pumpChat(tester, provider);

    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'favorite-image:/api/emoji/favorites/11/file',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 点击即发送，不出现 composer preview，也不重新上传。
    expect(find.byType(StickerComposerPreview), findsNothing);
    expect(provider.messages, hasLength(1));
    expect(sentData?['file_id'], 77);
    expect(uploadRequests, 0);

    await _disposeChat(tester, provider);
  });

  testWidgets('private message image sends the bearer token', (tester) async {
    final provider = MessageProvider(
      _chatDio(messages: [
        {
          'id': 89,
          'conversation_id': 42,
          'sender_id': 3,
          'content': '',
          'file_id': 99,
          'file': {
            'id': 99,
            'mime_type': 'image/jpeg',
            'size': 1024,
            'download_url': '/api/messages/files/99',
          },
          'created_at': '2026-08-11T12:00:00Z',
        },
      ]),
    );
    await _pumpChat(tester, provider);

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(image.httpHeaders, {'Authorization': 'Bearer test-token'});
    await _disposeChat(tester, provider);
  });

  testWidgets('incoming message while reading history shows new message button',
      (tester) async {
    final initialMessages = _historyMessages();
    final provider = MessageProvider(_chatDio(messages: initialMessages));
    await _pumpChat(tester, provider);

    // reverse 列表在 offset=0 时位于最新消息，向下拖动才会进入历史区。
    await tester.drag(find.byType(ListView).first, const Offset(0, 420));
    await tester.pump();
    provider.applyRealtimeEventForTest('message.created', {
      'message': {
        'id': 31,
        'conversation_id': 42,
        'sender_id': 3,
        'content': '刚收到的消息',
        'created_at': '2026-06-14T08:31:00Z',
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('1 条新消息'), findsOneWidget);
    await _disposeChat(tester, provider);
  });

  testWidgets('message focus request scrolls a loaded target into view',
      (tester) async {
    final provider = MessageProvider(
      _chatDio(messages: _historyMessages()),
    );
    await _pumpChat(tester, provider);

    await provider.requestMessageFocus(1);
    await _pumpFrames(tester);

    expect(find.text('历史消息 1').hitTestable(), findsOneWidget);
    await _disposeChat(tester, provider);
  });

  testWidgets('covering route deactivates chat and defers read receipt',
      (tester) async {
    var readCount = 0;
    final provider = MessageProvider(
      _chatDio(
        messages: [_historyMessages().last],
        onRead: () => readCount++,
      ),
    );
    await _pumpChat(tester, provider);
    final readsBeforeCover = readCount;
    expect(provider.activeConversationId, 42);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('覆盖页面')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(provider.activeConversationId, isNull);

    provider.applyRealtimeEventForTest('message.created', {
      'message': {
        'id': 31,
        'conversation_id': 42,
        'sender_id': 3,
        'content': '覆盖期间收到',
        'created_at': '2026-06-14T08:31:00Z',
      },
    });
    await _pumpFrames(tester, count: 3);
    expect(readCount, readsBeforeCover);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(provider.activeConversationId, 42);
    expect(readCount, greaterThan(readsBeforeCover));
    await _disposeChat(tester, provider);
  });

  testWidgets('returning from a covered route restores the original chat',
      (tester) async {
    final provider = MessageProvider(
      _chatDio(
        messages: [_historyMessages().last],
        otherMessages: [
          {
            'id': 70,
            'conversation_id': 7,
            'sender_id': 4,
            'content': '另一个会话',
            'created_at': '2026-06-14T09:00:00Z',
          },
        ],
      ),
    );
    await _pumpChat(tester, provider);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('覆盖页面')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => provider.loadMessages(7));
    expect(provider.currentConversationId, 7);

    navigator.pop();
    await tester.pumpAndSettle();

    expect(provider.currentConversationId, 42);
    expect(provider.activeConversationId, 42);
    expect(provider.messages.single.conversationId, 42);
    await _disposeChat(tester, provider);
  });
}

List<Map<String, dynamic>> _historyMessages() {
  return List.generate(
    30,
    (index) => {
      'id': index + 1,
      'conversation_id': 42,
      'sender_id': 3,
      'content': '历史消息 ${index + 1}',
      'created_at': DateTime.utc(2026, 6, 14, 8, index).toIso8601String(),
    },
  );
}

Dio _chatDio({
  List<Map<String, dynamic>> messages = const [],
  List<Map<String, dynamic>> otherMessages = const [],
  Completer<void>? failureGate,
  VoidCallback? onRead,
  VoidCallback? onUpload,
  ValueChanged<Map<String, dynamic>>? onSend,
  Map<String, dynamic> sendState = const {'can_send': true},
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.method == 'GET' &&
            options.path == '/messages/conversations/42') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: messages,
            ),
          );
          return;
        }
        if (options.method == 'GET' &&
            options.path == '/messages/conversations/7') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: otherMessages,
            ),
          );
          return;
        }
        if (options.method == 'GET' &&
            options.path == '/messages/3/send-state') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: sendState,
            ),
          );
          return;
        }
        if (options.method == 'POST' &&
            options.path == '/messages/conversations/42/read') {
          onRead?.call();
          handler.resolve(Response(requestOptions: options, statusCode: 200));
          return;
        }
        if (options.method == 'POST' && options.path == '/messages/3') {
          final data = Map<String, dynamic>.from(options.data as Map);
          onSend?.call(data);
          if (failureGate != null) {
            failureGate.future.then((_) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'offline',
                ),
              );
            });
            return;
          }
          if (onSend != null) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 201,
                data: _messageJson(
                  id: 900,
                  clientMessageId: data['client_message_id'] as String,
                  content: data['content'] as String? ?? '',
                ),
              ),
            );
            return;
          }
        }
        if (options.method == 'POST' && options.path == '/upload') {
          onUpload?.call();
        }
        handler.reject(
          DioException(
            requestOptions: options,
            message: 'Unexpected request: ${options.method} ${options.path}',
          ),
        );
      },
    ),
  );
  return dio;
}

Future<void> _pumpChat(
  WidgetTester tester,
  MessageProvider provider, {
  ThemeData? theme,
  bool disableAnimations = false,
}) async {
  final currentUser = _user(8, '我');
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(
          value: _FakeAuthProvider(currentUser),
        ),
        ChangeNotifierProvider<MessageProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        theme: theme,
        builder: disableAnimations
            ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: true,
                  ),
                  child: child!,
                )
            : null,
        navigatorObservers: [appRouteObserver],
        home: ChatDetailScreen(
          conversationId: 42,
          targetUser: _user(3, '对方'),
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
}

IconButton _sendButton(WidgetTester tester) {
  return tester.widget<IconButton>(
    find.byKey(const ValueKey('chat-send-button')),
  );
}

Future<void> _disposeChat(
  WidgetTester tester,
  MessageProvider provider,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  provider.dispose();
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

User _user(int id, String nickname) {
  return User(
    id: id,
    studentId: 'S$id',
    nickname: nickname,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

Map<String, dynamic> _messageJson({
  required int id,
  required String clientMessageId,
  String content = '',
}) {
  return {
    'id': id,
    'conversation_id': 42,
    'sender_id': 8,
    'client_message_id': clientMessageId,
    'content': content,
    'created_at': '2026-08-17T08:14:00Z',
  };
}
