import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/canteen_share_link.dart';

void main() {
  test('商家分享链接指向 Web 应用的商家详情路由', () {
    expect(canteenShareUri(42).toString(),
        'https://sylulive.online/web/canteen/42');
  });

  test('分享文案只含公开信息并附带可打开的链接', () {
    final text = canteenShareText(
      canteenId: 7,
      name: '川渝椒香',
      location: '一食堂 · 二楼',
      averageStar: 4.73,
      ratingCount: 9,
      dishName: '水煮鱼',
    );
    expect(text, contains('「川渝椒香」的「水煮鱼」'));
    expect(text, contains('4.7 分（9 位同学评价）'));
    expect(text, endsWith('https://sylulive.online/web/canteen/7'));
  });
}
