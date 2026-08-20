import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/canteen/canteen_detail_header.dart';
import 'package:shenliyuan/widgets/canteen/canteen_review_section.dart';
import 'package:shenliyuan/widgets/canteen/canteen_status_image.dart';

void main() {
  testWidgets('离线食堂图片只在客户端套灰度滤镜', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CanteenStatusImage(imageUrl: '', offline: true),
      ),
    );

    expect(find.byType(ColorFiltered), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: CanteenStatusImage(imageUrl: '', offline: false),
      ),
    );
    expect(find.byType(ColorFiltered), findsNothing);
  });

  testWidgets('离线食堂显示历史状态并关闭新评价入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          children: [
            const CanteenDetailHeader(
              name: '川渝椒香',
              rating: 4.6,
              ratingCount: 128,
              offline: true,
            ),
            CanteenReviewSection(
              reviews: const [],
              reviewCount: 128,
              sort: 'best',
              filter: 'all',
              dataVersion: 1,
              isRefreshing: false,
              isVoting: false,
              onSortChanged: (_) {},
              onFilterChanged: (_) {},
              onVote: (_, __, ___) async {},
              onWriteReview: () {},
              canWriteReview: false,
            ),
          ],
        ),
      ),
    );

    expect(find.text('已下架'), findsOneWidget);
    expect(find.text('该店当前已下架，历史评价仅供参考'), findsWidgets);
    expect(find.text('写第一条评价'), findsNothing);
  });
}
