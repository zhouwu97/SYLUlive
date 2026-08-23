import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/campus_map_tab_page.dart';

void main() {
  testWidgets('校园地图页面使用更新后的 PNG 地图资源', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CampusMapTabPage()),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;

    expect(
      provider.imageProvider,
      const AssetImage('assets/images/map.png'),
    );
  });
}
