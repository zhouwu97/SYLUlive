import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/canteen_status_image.dart';
import '../helpers/mock_public_image_http.dart';

void main() {
  testWidgets('再次进入从磁盘缓存显示中图，不重复下载', (tester) async {
    final requests = <String>[];
    await tester.runAsync(() => installMockPublicImageHttp(imageStatus: (uri) {
          requests.add(uri.path);
          return 200;
        }));
    addTearDown(uninstallMockPublicImageHttp);
    Widget page() => const MaterialApp(
            home: SizedBox(
          width: 160,
          height: 120,
          child: CanteenStatusImage(
              imageUrl: '/uploads/cached.jpg', variant: 'medium'),
        ));
    await tester.pumpWidget(page());
    await driveMockPublicImageLoads(tester);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    final firstRequests = List<String>.of(requests);
    expect(firstRequests, contains('/uploads/cached_v1_medium.jpg'));
    expect(firstRequests, isNot(contains('/uploads/cached.jpg')));
    await tester.pumpWidget(const SizedBox.shrink());
    // 清掉内存解码缓存，确保第二次验证的是磁盘命中。
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(page());
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    expect(requests, firstRequests);
  });
  testWidgets('图片权限恢复后重新进入可显示缩略图，不停留在加载占位', (tester) async {
    var available = false;
    await tester.runAsync(() => installMockPublicImageHttp(
          imageStatus: (_) => available ? 200 : 404,
        ));
    addTearDown(uninstallMockPublicImageHttp);
    Widget page() => const MaterialApp(
            home: SizedBox(
          width: 160,
          height: 120,
          child: CanteenStatusImage(
              imageUrl: '/uploads/recovered.jpg', variant: 'thumb'),
        ));
    await tester.pumpWidget(page());
    await driveMockPublicImageLoads(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    available = true;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(page());
    await driveMockPublicImageLoads(tester);
    await flushMockPublicImageTimers(tester);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsOneWidget);
  });
  testWidgets('铺满宽度（double.infinity）不再触发 build 异常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 120,
            child: Column(
              children: [
                Expanded(
                  child: CanteenStatusImage(
                    imageUrl: '/uploads/aa/bb.jpg',
                    variant: 'thumb',
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    placeholder: (_, __) => const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
