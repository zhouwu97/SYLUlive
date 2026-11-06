import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/widgets/ai_bot_identity.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';

import '../helpers/golden_viewport.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  test('公开AI归属经缓存序列化保留，普通昵称不能获得系统标记', () {
    final bot = User.fromJson({
      'id': 71,
      'nickname': '自定义机器人名称',
      'ai_bot': {'owner_id': 7, 'owner_nickname': '创建者'},
    });
    final restored = User.fromJson(bot.toJson());
    expect(restored.isAiBot, isTrue);
    expect(restored.botOwnerId, 7);
    expect(restored.aiBotLabel, '创建者 的 AI');
    expect(User.fromJson({'nickname': '[AI] 创建者的机器人'}).isAiBot, isFalse);
    expect(User.fromJson({'ai_bot': {}}).aiBotLabel, '独立 AI 机器人');
  });

  test('损坏或缺失创建者字段不能冒充身份，也不应使公共页面崩溃', () {
    for (final metadata in [true, 'AI', []]) {
      expect(User.fromJson({'nickname': '[AI] 模仿', 'ai_bot': metadata}).isAiBot,
          isFalse);
    }
    final unknown = User.fromJson({
      'ai_bot': {'owner_id': 'not-an-id', 'owner_nickname': {}},
    });
    expect(unknown.isAiBot, isTrue);
    expect(unknown.botOwnerId, isNull);
    expect(unknown.botOwnerNickname, isEmpty);
  });

  for (final profile in [
    (
      name: 'primary',
      size: GoldenViewports.phone360x800,
      dark: false,
      scale: 1.0
    ),
    (name: 'wide', size: GoldenViewports.phone390x844, dark: false, scale: 1.0),
    (name: 'dark', size: GoldenViewports.phone360x800, dark: true, scale: 1.0),
    (
      name: 'large',
      size: GoldenViewports.phone360x800,
      dark: false,
      scale: 1.3
    ),
    (
      name: 'dark-stress',
      size: GoldenViewports.phone360x800,
      dark: true,
      scale: 1.5
    ),
  ]) {
    testWidgets('社区和楼中楼显示系统AI归属，${profile.name}', (tester) async {
      await setGoldenViewport(tester, profile.size);
      final key = GlobalKey();
      final author = User.fromJson({
        'id': 71,
        'nickname': '大肥鱼',
        'ai_bot': {'owner_id': 7, 'owner_nickname': '校园创建者'},
      });
      await tester.pumpWidget(GoldenTestApp(
        themeMode: profile.dark ? ThemeMode.dark : ThemeMode.light,
        textScaler: TextScaler.linear(profile.scale),
        home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: PostReplyList(replies: [
                  Reply(
                    id: 1,
                    postId: 1,
                    authorId: author.id,
                    author: author,
                    content: '这是机器人自己的评论，社区规则同样适用。',
                    createdAt: DateTime(2026, 11, 2),
                  ),
                  Reply(
                    id: 2,
                    parentReplyId: 1,
                    replyToReplyId: 1,
                    postId: 1,
                    authorId: author.id,
                    author: author,
                    content: '楼中楼也应展示独立的系统身份。',
                    createdAt: DateTime(2026, 11, 2),
                  ),
                ], onReply: (_) {}),
              ),
            )),
      ));
      await tester.pumpAndSettle();
      expect(find.text('AI机器人'), findsNWidgets(2));
      expect(find.text('由校园创建者创建'), findsNWidgets(2));
      expect(find.byType(AiBotIdentity), findsNWidgets(2));
      expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final picture = await boundary.toImage();
        try {
          final bytes =
              await picture.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../scratch/bot-identity-20261104')
            ..createSync(recursive: true);
          File('${dir.path}/app-community-ai-${profile.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
        } finally {
          picture.dispose();
        }
      });
    });
  }

  testWidgets('普通昵称不显示徽标，缺少创建者和长归属在窄屏可读', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final semantics = tester.ensureSemantics();
    try {
      final owner = '校园创建者'.padRight(140, '长');
      await tester.pumpWidget(GoldenTestApp(
        textScaler: const TextScaler.linear(1.3),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 180,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AiBotIdentity(user: User.fromJson({'nickname': '[AI] 模仿'})),
                  AiBotIdentity(user: User.fromJson({'ai_bot': {}})),
                  AiBotIdentity(
                      user: User.fromJson({
                    'ai_bot': {'owner_id': 7, 'owner_nickname': owner},
                  })),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('AI机器人'), findsNWidgets(2));
      expect(find.text('创建者未公开'), findsOneWidget);
      expect(find.bySemanticsLabel('系统AI机器人，由$owner创建'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
