import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/canteen_review_section.dart';
import 'package:shenliyuan/utils/canteen_review_date.dart';

void main() {
  test('评价日期区分发布和更新，兼容缺失字段及时间精度误差', () {
    final created = DateTime(2026, 9, 7, 12);
    expect(formatCanteenReviewDate(created, null), '09-07 发布');
    expect(formatCanteenReviewDate(created, created), '09-07 发布');
    expect(formatCanteenReviewDate(created,
        created.add(const Duration(milliseconds: 500))), '09-07 发布');
    expect(formatCanteenReviewDate(created, DateTime(2026, 9, 10, 12)),
        '09-07 发布 · 09-10 更新');
    expect(formatCanteenReviewDate(created, DateTime(2026, 9, 7, 13)),
        '09-07 发布 · 09-07 更新');
    expect(formatCanteenReviewDate(created, DateTime(2026, 9, 6)), '09-07 发布');
    expect(formatCanteenReviewDate(null, created), '');
  });

  for (final brightness in Brightness.values) {
    testWidgets('编辑日期在窄屏大字号下完整显示 $brightness', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(body: SingleChildScrollView(child: CanteenReviewSection(
          reviews: const [{
            'id': 18, 'user_id': 7, 'user_name': '雪织儿',
            'star': 3, 'review_source': 'v2', 'comment': '修改后的评价',
            'created_at': '2026-09-07T12:00:00',
            'updated_at': '2026-09-10T12:00:00', 'credit_score': 100,
          }],
          reviewCount: 1, sort: 'latest', filter: 'all', dataVersion: 1,
          isRefreshing: false, isVoting: false, currentUserId: 99,
          onSortChanged: (_) {}, onFilterChanged: (_) {},
          onVote: (_, __, ___) async {},
        ))),
      ));
      expect(find.text('09-07 发布 · 09-10 更新'), findsOneWidget);
      expect(find.text('雪织儿 · 09-07 发布 · 09-10 更新 · 诚信 100'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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
