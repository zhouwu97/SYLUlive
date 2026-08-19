import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/unread_reply_notification.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/widgets/reply_notification_reminder.dart';

UnreadReplyNotification _notification(int id, String postTitle) {
  return UnreadReplyNotification(
    id: id,
    postId: 100,
    relatedId: id + 500,
    content: '这是一条用于测试的回复内容',
    postTitle: postTitle,
    createdAt: DateTime.utc(2026, 8, 18, 10),
    fromUser: User(
      id: 3,
      studentId: 'reply-author',
      nickname: '回复者B',
      avatar: '',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  );
}

Widget _testApp(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

void main() {
  testWidgets('单条提醒在首页只显示类型和数量并提供完整语义', (tester) async {
    final semantics = tester.ensureSemantics();
    var tapped = false;
    await tester.pumpWidget(
      _testApp(
        ReplyNotificationReminder(
          items: [_notification(11, '我的水帖')],
          totalCount: 1,
          onPressed: () => tapped = true,
        ),
      ),
    );

    expect(find.text('互动回复'), findsOneWidget);
    expect(find.text('1 条新回复'), findsOneWidget);
    // 首页紧凑入口不泄露回复人和正文
    expect(find.text('回复者B'), findsNothing);
    expect(find.text('这是一条用于测试的回复内容'), findsNothing);
    expect(find.text('《我的水帖》'), findsNothing);
    expect(find.bySemanticsLabel('互动回复，1 条未读，查看'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('home-reply-notification-reminder')),
          )
          .height,
      lessThanOrEqualTo(48),
    );
    await tester
        .tap(find.byKey(const ValueKey('home-reply-notification-reminder')));
    expect(tapped, isTrue);
    semantics.dispose();
  });

  testWidgets('多条列表选择在弹层中展示头像、昵称、摘要与原帖标题', (tester) async {
    UnreadReplyNotification? selected;
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showReplyNotificationList(
              context,
              items: [_notification(11, '我的水帖'), _notification(12, '第二篇帖子')],
              totalCount: 2,
              onSelected: (item) => selected = item,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('未读回复 (2)'), findsOneWidget);
    expect(find.text('回复于《我的水帖》'), findsOneWidget);
    expect(find.text('回复于《第二篇帖子》'), findsOneWidget);
    expect(find.text('回复者B'), findsWidgets);
    expect(find.text('这是一条用于测试的回复内容'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('reply-notification-12')));
    await tester.pumpAndSettle();
    expect(selected?.id, 12);
  });

  testWidgets('少量未读时底部弹层按内容收缩', (tester) async {
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showReplyNotificationList(
              context,
              items: [_notification(11, '我的水帖'), _notification(12, '第二篇帖子')],
              onSelected: (_) {},
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final sheet = find.ancestor(
      of: find.text('未读回复 (2)'),
      matching: find.byType(Material),
    );
    final sheetHeight = tester.getSize(sheet.first).height;
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(sheetHeight, lessThan(viewportHeight * 0.5));
  });

  testWidgets('未读数量超过20条时展示总数与最近20条标注', (tester) async {
    final items = List.generate(
      20,
      (index) => _notification(index + 1, '测试帖子 ${index + 1}'),
    );
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showReplyNotificationList(
              context,
              items: items,
              totalCount: 37,
              onSelected: (_) {},
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('未读回复 37'), findsOneWidget);
    expect(find.text('最近 20 条'), findsOneWidget);
  });

  testWidgets('大量未读时弹层限制高度且列表可滚动', (tester) async {
    final items = List.generate(
      20,
      (index) => _notification(index + 1, '测试帖子 ${index + 1}'),
    );
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showReplyNotificationList(
              context,
              items: items,
              totalCount: 20,
              onSelected: (_) {},
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final sheet = find.ancestor(
      of: find.text('未读回复 (20)'),
      matching: find.byType(Material),
    );
    final sheetHeight = tester.getSize(sheet.first).height;
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(sheetHeight, lessThanOrEqualTo(viewportHeight * 0.7 + 1));

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(find.byKey(const ValueKey('reply-notification-20')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reply-notification-20')),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-notification-20')), findsOneWidget);
  });

  testWidgets('1.3 倍文字不产生溢出异常', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: _testApp(
          ReplyNotificationReminder(
            items: [_notification(11, '这是一个用于大字号换行的很长帖子标题')],
            totalCount: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式保持紧凑入口', (tester) async {
    await tester.pumpWidget(
      Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: _testApp(
          ReplyNotificationReminder(
            items: [_notification(11, '我的水帖')],
            totalCount: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('回复者B'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未读数量靠右贴近箭头', (tester) async {
    await tester.pumpWidget(
      _testApp(
        SizedBox(
          width: 320,
          child: ReplyNotificationReminder(
            items: [_notification(11, '我的水帖')],
            totalCount: 1,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final reminderRect = tester.getRect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
    );
    final countRect = tester.getRect(find.text('1 条新回复'));
    expect(reminderRect.right - countRect.right, lessThanOrEqualTo(48));
  });
}
