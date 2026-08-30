import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/canteen_dish.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/widgets/canteen/dish_gallery_section.dart';

import '../../helpers/mock_public_image_http.dart';

CanteenDish _dish(
  int id,
  String name, {
  String coverImage = '',
  String source = '',
  int photoCount = 1,
}) {
  return CanteenDish(
    id: id,
    name: name,
    coverImage: coverImage,
    photoCount: photoCount,
    lastPhotoAt: '2026-08-13',
    source: source,
  );
}

Widget _wrap(
  List<CanteenDish> dishes, {
  void Function(int, int, int)? onStatsDetailedChanged,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(Dio())),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DishGallerySection(
            canteenId: 1,
            canteenName: '我家有面',
            initialDishes: dishes,
            onStatsDetailedChanged: onStatsDetailedChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('无实拍地址的菜品不渲染卡片，有图菜品保留', (tester) async {
    await tester.pumpWidget(_wrap([
      _dish(1, '麻辣拌', coverImage: '/uploads/a.jpg'),
      _dish(2, '无图凉菜'),
      _dish(3, '空白地址菜', coverImage: '   '),
    ]));
    await tester.pump();

    expect(find.text('商家菜品'), findsOneWidget);
    expect(find.text('麻辣拌'), findsOneWidget);
    expect(find.text('无图凉菜'), findsNothing);
    expect(find.text('空白地址菜'), findsNothing);
  });

  testWidgets('全部菜品无图时整个模块收起', (tester) async {
    await tester.pumpWidget(_wrap([
      _dish(1, '无图凉菜'),
      _dish(2, '空白地址菜', coverImage: ' '),
    ]));
    await tester.pump();

    expect(find.text('商家菜品'), findsNothing);
    expect(find.text('无图凉菜'), findsNothing);
  });

  testWidgets('图片加载确认 404 后菜品卡移除，有图菜品保留', (tester) async {
    await tester.runAsync(() => installMockPublicImageHttp());
    addTearDown(uninstallMockPublicImageHttp);

    await tester.pumpWidget(_wrap([
      _dish(1, '失效图菜', coverImage: '/uploads/missing.jpg'),
      _dish(2, '正常菜', coverImage: '/uploads/ok.jpg'),
    ]));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    expect(find.text('失效图菜'), findsNothing);
    expect(find.text('正常菜'), findsOneWidget);
    expect(find.text('商家菜品'), findsOneWidget);
  });

  testWidgets('瞬时故障（500）菜品卡保留并展示重试占位', (tester) async {
    await tester.runAsync(() => installMockPublicImageHttp());
    addTearDown(uninstallMockPublicImageHttp);

    await tester.pumpWidget(_wrap([
      _dish(1, '抖动图菜', coverImage: '/uploads/flaky.jpg'),
      _dish(2, '正常菜', coverImage: '/uploads/ok.jpg'),
    ]));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    expect(find.text('抖动图菜'), findsOneWidget);
    expect(find.text('正常菜'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });

  testWidgets('统计回传排除评价图聚合且区分有实拍菜品数', (tester) async {
    int? realDishCount;
    int? withPhotoCount;
    int? photoCount;
    await tester.pumpWidget(_wrap(
      [
        _dish(1, '麻辣拌', coverImage: '/uploads/a.jpg', photoCount: 2),
        _dish(2, '无图凉菜', photoCount: 0),
        _dish(0, '', source: 'review_images', photoCount: 3),
      ],
      onStatsDetailedChanged: (dishCount, dishWithPhoto, dishPhoto) {
        realDishCount = dishCount;
        withPhotoCount = dishWithPhoto;
        photoCount = dishPhoto;
      },
    ));
    await tester.pump();

    expect(realDishCount, 2);
    expect(withPhotoCount, 1);
    expect(photoCount, 5);
  });
}
