import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_ranking.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_item.dart';

void main() {
  test('ranked 字段缺失时按评价人数判断是否参与名次', () {
    final rated = CanteenRankingItem.fromJson(
        {'rank': 3, 'id': 1, 'name': 'A', 'rating_count': 2});
    final unrated = CanteenRankingItem.fromJson(
        {'rank': 9, 'id': 2, 'name': 'B', 'rating_count': 0});
    final explicit = CanteenRankingItem.fromJson(
        {'rank': 4, 'id': 3, 'name': 'C', 'rating_count': 0, 'ranked': true});
    expect(rated.ranked, isTrue);
    expect(unrated.ranked, isFalse);
    expect(explicit.ranked, isTrue);
  });

  Future<void> pumpTile(WidgetTester tester, CanteenRankingItem item) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CanteenRankingItemTile(item: item, onTap: () {}),
      ),
    ));
    await tester.pump();
  }

  testWidgets('无人评价的店显示“—”而不是名次', (tester) async {
    await pumpTile(
        tester,
        CanteenRankingItem.fromJson({
          'rank': 131,
          'ranked': false,
          'id': 9,
          'name': '新开小炒',
          'rating_count': 0,
        }));
    expect(find.text('—'), findsOneWidget);
    expect(find.text('131'), findsNothing);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('暂无评价，不参与排名')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('有评价的店照常显示两位名次', (tester) async {
    await pumpTile(
        tester,
        CanteenRankingItem.fromJson({
          'rank': 2,
          'ranked': true,
          'id': 1,
          'name': '川渝椒香',
          'rating_count': 9,
          'average_star': 4.7,
        }));
    expect(find.text('02'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('第2名')), findsOneWidget);
    semantics.dispose();
  });
}
