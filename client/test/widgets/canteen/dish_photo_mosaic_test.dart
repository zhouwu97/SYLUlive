import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/dish_photo_mosaic.dart';

import '../../helpers/mock_public_image_http.dart';

Widget _wrap(List<String> imageUrls, {ValueChanged<String>? onImageError}) {
  return MaterialApp(
    home: Scaffold(
      body: DishPhotoMosaic(
        imageUrls: imageUrls,
        onImageError: onImageError,
      ),
    ),
  );
}

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

  testWidgets('空地址与空白地址在渲染前过滤，不生成网络图片', (tester) async {
    await tester.pumpWidget(_wrap(['', '   ', '/uploads/ok.jpg']));
    await tester.pump();

    final networkImages = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(networkImages, hasLength(1));
    expect(networkImages.single.imageUrl, contains('ok_v1_medium.jpg'));
  });

  testWidgets('图片加载失败后自动移除该图，图库收起并回传失败地址', (tester) async {
    await tester.runAsync(() => installMockPublicImageHttp());
    addTearDown(uninstallMockPublicImageHttp);

    final failedUrls = <String>[];
    await tester.pumpWidget(_wrap(
      ['/uploads/missing.jpg'],
      onImageError: failedUrls.add,
    ));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    expect(failedUrls, contains('/uploads/missing.jpg'));
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('多图时失败图片被移除，其余图片保留', (tester) async {
    await tester.runAsync(() => installMockPublicImageHttp());
    addTearDown(uninstallMockPublicImageHttp);

    await tester.pumpWidget(_wrap(
      ['/uploads/missing.jpg', '/uploads/ok.jpg'],
    ));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    final networkImages = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(networkImages, hasLength(1));
    expect(networkImages.single.imageUrl, contains('ok_v1_medium.jpg'));
  });

  testWidgets('瞬时错误（500）图片保留占位，不触发移除回传', (tester) async {
    await tester.runAsync(() => installMockPublicImageHttp());
    addTearDown(uninstallMockPublicImageHttp);

    final failedUrls = <String>[];
    await tester.pumpWidget(_wrap(
      ['/uploads/flaky.jpg', '/uploads/ok.jpg'],
      onImageError: failedUrls.add,
    ));
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);

    expect(failedUrls, isEmpty);
    // 变体 500 后回退原图也 500：外层与回退层同时存在
    expect(
      find.byWidgetPredicate((w) =>
          w is CachedNetworkImage && w.imageUrl.contains('flaky_v1_medium.jpg')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) =>
          w is CachedNetworkImage && w.imageUrl.contains('ok_v1_medium.jpg')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });
}
