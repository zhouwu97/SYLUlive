import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_card.dart';

Widget _wrap(Widget child, {double width = 320}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: child,
        ),
      ),
    ),
  );
}

Widget _card({
  int rank = 1,
  String name = '一食堂二楼',
  String imageUrl = '',
  double averageStar = 4.8,
  int ratingCount = 86,
  int dishCount = 12,
  int dishPhotoCount = 26,
}) {
  return CanteenRankingCard(
    rank: rank,
    canteenId: 1,
    name: name,
    imageUrl: imageUrl,
    averageStar: averageStar,
    ratingCount: ratingCount,
    dishCount: dishCount,
    dishPhotoCount: dishPhotoCount,
    onTap: () {},
  );
}

void main() {
  testWidgets('320px 宽度渲染无溢出', (tester) async {
    await tester.pumpWidget(_wrap(_card()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('一食堂二楼'), findsOneWidget);
  });

  testWidgets('菜品统计行按值渲染', (tester) async {
    await tester.pumpWidget(_wrap(_card(dishCount: 12, dishPhotoCount: 26)));
    await tester.pump();

    expect(find.text('12 道菜 · 26 张同学实拍'), findsOneWidget);
    expect(find.text('86 条评价'), findsOneWidget);
  });

  testWidgets('无实拍时显示占位文案', (tester) async {
    await tester.pumpWidget(_wrap(_card(dishCount: 0, dishPhotoCount: 0)));
    await tester.pump();

    expect(find.text('暂无实拍'), findsOneWidget);
  });

  testWidgets('排名 badge 颜色：1金 2银 3铜 4灰', (tester) async {
    const expected = {
      1: Color(0xFFFFB800),
      2: Color(0xFF94A3B8),
      3: Color(0xFFCA8A4B),
      4: Color(0xFF9CA3AF),
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(_wrap(_card(rank: entry.key)));
      await tester.pump();

      final badge = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) => w is Container && (w.decoration is BoxDecoration),
        ),
      );
      Container? target;
      for (final c in badge) {
        final deco = c.decoration as BoxDecoration?;
        if (deco?.color == entry.value) {
          target = c;
          break;
        }
      }
      expect(target, isNotNull, reason: 'rank ${entry.key} badge color not found');
    }
  });

  testWidgets('onTap 点击触发', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _wrap(CanteenRankingCard(
        rank: 1,
        canteenId: 1,
        name: '一食堂二楼',
        averageStar: 4.8,
        ratingCount: 86,
        onTap: () => tapped++,
      )),
    );
    await tester.pump();

    await tester.tap(find.text('一食堂二楼'));
    expect(tapped, 1);
  });
}
