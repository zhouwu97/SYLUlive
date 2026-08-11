import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/feed/feed_post_action_menu.dart';

void main() {
  testWidgets('综合流显示不感兴趣，关注流隐藏该操作', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedPostActionMenu(
            isMine: false,
            isDark: false,
            allowNotInterested: false,
            onAction: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('不感兴趣'), findsNothing);
    expect(find.text('不看 TA'), findsOneWidget);
    expect(find.text('举报'), findsOneWidget);
  });

  testWidgets('综合流保留不感兴趣入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedPostActionMenu(
            isMine: false,
            isDark: false,
            onAction: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('不感兴趣'), findsOneWidget);
  });
}
