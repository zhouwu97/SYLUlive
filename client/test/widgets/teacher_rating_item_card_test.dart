import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/cached_avatar.dart';
import 'package:shenliyuan/widgets/rating_detail/teacher_rating_item_card.dart';

void main() {
  testWidgets('教师评价卡在用户没有头像时显示默认用户图标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TeacherRatingItemCard(
            userName: 'Konien',
            comment: '上得最爽的一节',
            star: 5,
            accent: Color(0xFF147C72),
          ),
        ),
      ),
    );

    expect(find.byType(CachedAvatar), findsOneWidget);
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.text('K'), findsNothing);
  });

  testWidgets('教师评价卡展示用户头像并保持紧凑高度', (tester) async {
    const avatarUrl = 'https://example.com/avatar.png';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 360,
              child: TeacherRatingItemCard(
                userName: '柯同学',
                userAvatar: avatarUrl,
                comment: '课程讲解清楚',
                star: 5,
                accent: Color(0xFF147C72),
              ),
            ),
          ),
        ),
      ),
    );

    final avatar = tester.widget<CachedAvatar>(find.byType(CachedAvatar));
    expect(avatar.imageUrl, avatarUrl);
    expect(avatar.radius, 17);
    expect(
      tester.getSize(find.byType(TeacherRatingItemCard)).height,
      lessThan(140),
    );
  });
}
