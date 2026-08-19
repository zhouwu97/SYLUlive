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

    expect(find.text('12 道菜 · 26 张实拍'), findsOneWidget);
    expect(find.text('86 人评价'), findsOneWidget);
  });

  testWidgets('无实拍时显示低权重占位文案', (tester) async {
    await tester.pumpWidget(_wrap(_card(dishCount: 0, dishPhotoCount: 0)));
    await tester.pump();

    expect(find.text('暂无同学实拍'), findsOneWidget);
  });

  testWidgets('排名排版数字颜色：1金 2银 3铜 4灰', (tester) async {
    const expected = {
      1: Color(0xFFD68A20),
      2: Color(0xFF87909A),
      3: Color(0xFFA66A43),
      4: Color(0xFFB0B3B7),
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(_wrap(_card(rank: entry.key)));
      await tester.pump();

      final label = entry.key.toString().padLeft(2, '0');
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.color, entry.value,
          reason: 'rank ${entry.key} color mismatch');
    }
  });

  testWidgets('排名无 badge 容器（纯排版数字）', (tester) async {
    await tester.pumpWidget(_wrap(_card(rank: 1)));
    await tester.pump();

    expect(find.text('01'), findsOneWidget);
    // 不再有覆盖在图片上的 badge 容器
    expect(find.byType(Badge), findsNothing);
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
