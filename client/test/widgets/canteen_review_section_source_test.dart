import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/canteen_review_section.dart';

void main() {
  testWidgets('相同数字 ID 的新版和旧版评价仍按来源分别投票', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanteenReviewSection(
            reviews: const [
              {
                'id': 17,
                'user_id': 1,
                'user_name': '旧版用户',
                'star': 4,
                'review_source': 'legacy',
              },
              {
                'id': 17,
                'user_id': 2,
                'user_name': '新版用户',
                'star': 4,
                'review_source': 'v2',
              },
            ],
            reviewCount: 2,
            sort: 'best',
            filter: 'all',
            dataVersion: 1,
            isRefreshing: false,
            isVoting: false,
            currentUserId: 99,
            onSortChanged: (_) {},
            onFilterChanged: (_) {},
            onVote: (id, source, vote) async {
              calls.add('$id:$source:$vote');
            },
          ),
        ),
      ),
    );

    final buttons = find.byIcon(Icons.thumb_up_alt_outlined);
    expect(buttons, findsNWidgets(2));
    await tester.tap(buttons.at(0));
    await tester.tap(buttons.at(1));

    expect(calls, ['17:legacy:up', '17:v2:up']);
    expect(find.byKey(const ValueKey('legacy:17')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2:17')), findsOneWidget);
  });

  testWidgets('只有自己的最新 V2 评价显示修改菜单', (tester) async {
    var editCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanteenReviewSection(
            reviews: const [
              {
                'id': 18,
                'user_id': 7,
                'user_name': '我',
                'star': 4,
                'review_source': 'v2',
                'comment': '最新体验',
              },
              {
                'id': 17,
                'user_id': 7,
                'user_name': '我',
                'star': 3,
                'review_source': 'v2',
                'comment': '旧体验',
              },
              {
                'id': 16,
                'user_id': 7,
                'user_name': '我',
                'star': 5,
                'review_source': 'legacy',
                'comment': '旧版摘要',
              },
            ],
            reviewCount: 3,
            sort: 'latest',
            filter: 'all',
            dataVersion: 1,
            isRefreshing: false,
            isVoting: false,
            currentUserId: 7,
            latestReviewId: 18,
            onEditLatestReview: () => editCalls++,
            onSortChanged: (_) {},
            onFilterChanged: (_) {},
            onVote: (_, __, ___) async {},
          ),
        ),
      ),
    );

    final menus = find.byType(PopupMenuButton<String>);
    expect(menus, findsOneWidget);
    await tester.tap(menus);
    await tester.pumpAndSettle();
    expect(find.text('修改这条评价'), findsOneWidget);
    await tester.tap(find.text('修改这条评价'));
    expect(editCalls, 1);
  });
}
