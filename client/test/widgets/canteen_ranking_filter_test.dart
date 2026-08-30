import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_ranking.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_filter.dart';

CanteenRankingItem _item(
  int id,
  String name, {
  String area = '',
  String floor = '',
}) {
  return CanteenRankingItem(
    rank: 1,
    id: id,
    name: name,
    locationArea: area,
    locationFloor: floor,
    image: '',
    operatingStatus: 'active',
    averageStar: 4.5,
    ratingCount: 10,
    rankingScore: 80,
    confidence: 'high',
    dishCount: 0,
    dishWithPhotoCount: 0,
    dishPhotoCount: 0,
    summaryTags: const [],
  );
}

void main() {
  group('canteenRankingItemMatchesLocation 组合筛选', () {
    final a1f1 = _item(1, '一楼店', area: '一食堂', floor: '一楼');
    final a1f2 = _item(2, '一食堂二楼店', area: '一食堂', floor: '二楼');
    final noLoc = _item(3, '无位置店');

    test('区域 + 楼层同时命中', () {
      expect(canteenRankingItemMatchesLocation(a1f1, '一食堂', '一楼'), isTrue);
      expect(canteenRankingItemMatchesLocation(a1f2, '一食堂', '一楼'), isFalse);
    });

    test('只选楼层时跨区域命中', () {
      expect(canteenRankingItemMatchesLocation(a1f1, '', '一楼'), isTrue);
      expect(canteenRankingItemMatchesLocation(a1f2, '', '一楼'), isFalse);
    });

    test('只选区域时跨楼层命中', () {
      expect(canteenRankingItemMatchesLocation(a1f1, '一食堂', ''), isTrue);
      expect(canteenRankingItemMatchesLocation(a1f2, '一食堂', ''), isTrue);
    });

    test('全不选返回全部；无位置商家仅在全不选时出现', () {
      expect(canteenRankingItemMatchesLocation(noLoc, '', ''), isTrue);
      expect(canteenRankingItemMatchesLocation(noLoc, '一食堂', ''), isFalse);
      expect(canteenRankingItemMatchesLocation(noLoc, '', '一楼'), isFalse);
    });
  });

  group('canteenLocationFilterLabel', () {
    test('组合与空值文案', () {
      expect(canteenLocationFilterLabel('', ''), '位置');
      expect(canteenLocationFilterLabel('一食堂', ''), '一食堂');
      expect(canteenLocationFilterLabel('', '二楼'), '二楼');
      expect(canteenLocationFilterLabel('一食堂', '一楼'), '一食堂·一楼');
    });
  });

  testWidgets('筛选弹层支持区域+楼层组合后应用', (tester) async {
    String? appliedArea;
    String? appliedFloor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanteenRankingFilterBar(
            selected: CanteenRankingSort.composite,
            onChanged: (_) {},
            onLocationFilterChanged: (area, floor) {
              appliedArea = area;
              appliedFloor = floor;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('位置'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('一食堂'));
    await tester.pump();
    await tester.tap(find.text('一楼'));
    await tester.pump();

    await tester.tap(find.text('看一食堂·一楼'));
    await tester.pumpAndSettle();

    expect(appliedArea, '一食堂');
    expect(appliedFloor, '一楼');
  });

  testWidgets('重置清空两个维度', (tester) async {
    String? appliedArea = '一食堂';
    String? appliedFloor = '一楼';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanteenRankingFilterBar(
            selected: CanteenRankingSort.composite,
            onChanged: (_) {},
            locationArea: appliedArea,
            locationFloor: appliedFloor,
            onLocationFilterChanged: (area, floor) {
              appliedArea = area;
              appliedFloor = floor;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('一食堂·一楼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();

    expect(appliedArea, '');
    expect(appliedFloor, '');
  });
}
