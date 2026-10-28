import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/models/unread_reply_notification.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';
import 'package:shenliyuan/widgets/reply_notification_reminder.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

// Windows 仅输出人工审阅证据，不生成或更新 canonical Golden。
const _outputDirectory = String.fromEnvironment('REPLY_QA_OUTPUT');

Future<void> _capture(WidgetTester tester, String name) async {
  if (_outputDirectory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('reply-qa-canvas')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(_outputDirectory).create(recursive: true);
    await File('$_outputDirectory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadTestFonts);
  for (final profile in [
    ('light', ThemeMode.light, 1.0),
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3),
    ('stress', ThemeMode.dark, 1.5),
  ]) {
    testWidgets('回复对象和一键已读真实布局 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final controller = PostReplyComposerController();
      addTearDown(controller.dispose);
      controller.setReplyTarget(
        parentReplyId: 1,
        replyToUserId: 2,
        replyToReplyId: 3,
        replyToName: '昵称包含空格的测试同学',
      );
      controller.textController.text = '这份草稿会发给上面显示的对象';
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('reply-qa-canvas'),
        child: GoldenTestApp(
          themeMode: profile.$2,
          textScaler: TextScaler.linear(profile.$3),
          home: Scaffold(
            appBar: AppBar(title: const Text('评论与互动')),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Builder(
                    builder: (context) => TextButton(
                          onPressed: () => showReplyNotificationList(
                            context,
                            items: [
                              UnreadReplyNotification(
                                id: 11,
                                postId: 100,
                                relatedId: 2,
                                content: '这是你收到的最新回复',
                                postTitle: '校园里的新鲜事',
                                createdAt: DateTime(2026, 10, 19),
                              )
                            ],
                            totalCount: 37,
                            onSelected: (_) {},
                            onMarkAllRead: () async {},
                          ),
                          child: const Text('查看互动回复'),
                        )),
              ),
              Expanded(
                  child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: PostReplyList(replies: [
                  Reply(
                      id: 1,
                      postId: 100,
                      authorId: 2,
                      content: '讨论一下这张图片吧',
                      createdAt: DateTime(2026)),
                  Reply(
                      id: 2,
                      postId: 100,
                      parentReplyId: 1,
                      authorId: 3,
                      replyToName: '昵称包含空格的测试同学',
                      content: '收到，图片内容很清晰',
                      createdAt: DateTime(2026)),
                ], onReply: (_) {}),
              )),
              PostReplyComposer(
                  controller: controller,
                  sending: false,
                  enabled: true,
                  onSubmit: (_) async => false,
                  onNeedLogin: () {}),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('回复 @昵称包含空格的测试同学'), findsOneWidget);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('post-reply-clear-target')))
              .height,
          greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      await _capture(tester, 'reply-target-${profile.$1}');
      await tester.tap(find.text('查看互动回复'));
      await tester.pumpAndSettle();
      expect(find.text('一键已读'), findsOneWidget);
      expect(
          tester
              .getSize(find
                  .byKey(const ValueKey('reply-notifications-mark-all-read')))
              .height,
          greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      await _capture(tester, 'reply-notifications-${profile.$1}');
    });
  }
}
