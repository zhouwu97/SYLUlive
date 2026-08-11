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
  testWidgets('empty composer disables send and text enables it',
      (tester) async {
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

    expect(_sendButton(tester).onPressed, isNull);
    expect(_sendButtonOpacity(tester).opacity, 0);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    final enabledSendButton = _sendButton(tester);
    expect(enabledSendButton.onPressed, isNotNull);
    expect(
      enabledSendButton.style?.backgroundColor?.resolve({}),
      const Color(0xFF6366F1),
    );
    expect(_sendButtonOpacity(tester).opacity, 1);
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
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
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

  testWidgets('keyboard and Emoji panel share the remembered viewport height',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = MessageProvider(_chatDio());
    await _pumpChat(tester, provider);

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
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dy,
      closeTo(composerTopWithKeyboard, 1),
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
    await tester.pump();
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
      'tapping a sticker shows preview and sends with text when send button is tapped',
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

    // 点击 sticker 后显示 StickerComposerPreview 预览，尚不直接发送
    expect(find.byType(StickerComposerPreview), findsOneWidget);
    expect(provider.messages, isEmpty);
    expect(provider.draftStickerFor(3), sticker.id);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chat-input')))
          .controller
          ?.text,
      '晚安',
    );

    // 点击发送按钮后提交文字 + sticker
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();

    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.stickerId, sticker.id);
    expect(provider.messages.single.content, '晚安');
    expect(provider.messages.single.isPending, isTrue);
    expect(find.byType(StickerComposerPreview), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chat-input')))
          .controller
          ?.text,
      isEmpty,
    );

    failureGate.complete();
    await _pumpFrames(tester);

    expect(provider.messages.single.isFailed, isTrue);
    expect(provider.draftFor(3), isEmpty);
    expect(provider.draftStickerFor(3), isNull);
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

    // 从未弹起过键盘，直接点击 Emoji 按钮
    await tester.tap(find.byKey(const ValueKey('chat-emoji-button')));
    await _pumpFrames(tester, count: 2);
    expect(find.byType(AppEmojiPanel), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-bottom-viewport'))).height,
      300,
    );

    // 点击输入框切回键盘 (keyboardRequestPending = true)
    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();

    // 模拟 Android 真机 IME 首次逐帧弹起动画：0 -> 40 -> 100 -> 180 -> 260 -> 356
    final transitionFrames = [0.0, 40.0, 100.0, 180.0, 260.0, 356.0];
    for (final inset in transitionFrames) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
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
  MessageProvider provider,
) async {
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

AnimatedOpacity _sendButtonOpacity(WidgetTester tester) {
  return tester.widget<AnimatedOpacity>(
    find.ancestor(
      of: find.byKey(const ValueKey('chat-send-button')),
      matching: find.byType(AnimatedOpacity),
    ),
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
