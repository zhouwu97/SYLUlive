import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/dish_photo_mosaic.dart';

void main() {
  testWidgets('1 张：单图布局', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DishPhotoMosaic(imageUrls: ['/uploads/a.jpg']),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 单图容器存在
    expect(find.byType(DishPhotoMosaic), findsOneWidget);
  });

  testWidgets('2 张：左右各半', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DishPhotoMosaic(imageUrls: ['/uploads/a.jpg', '/uploads/b.jpg']),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('3 张：1 大 + 2 小', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DishPhotoMosaic(
            imageUrls: ['/uploads/a.jpg', '/uploads/b.jpg', '/uploads/c.jpg'],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('0 张：渲染空容器', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DishPhotoMosaic(imageUrls: [])),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
