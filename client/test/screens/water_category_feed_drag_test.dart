import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/config/water_post_taxonomy.dart';
import 'package:shenliyuan/models/water_section.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/water_moderator_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/water_category_feed_screen.dart';

void main() {
  testWidgets('小白条拖动测试：列表已滚动时拖动小白条向下可将抽屉拉下', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1179, 2556);
    addTearDown(tester.view.reset);

    final postDio = Dio();
    postDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'posts': List.generate(
                  20,
                  (i) => {
                    'id': i + 1,
                    'title': '测试帖子 $i',
                    'content': '测试内容 $i',
                    'author': {'id': 1, 'name': '测试用户'},
                    'createdAt': '2026-08-01T00:00:00Z',
                  },
                ),
                'total': 20,
              },
            ),
          );
        },
      ),
    );

    final category = kWaterPostCategories.firstWhere(
      (item) => item.value == 'competition',
    );
    final section = WaterSection.fromLegacyCategory(category);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: AuthProvider(Dio())),
          ChangeNotifierProvider.value(value: WaterSectionProvider(Dio())),
          ChangeNotifierProvider.value(value: WaterModeratorProvider(Dio())),
          ChangeNotifierProvider.value(
            value: PostProvider(postDio, enableCache: false),
          ),
        ],
        child: MaterialApp(
          home: WaterCategoryFeedScreen(
            category: category,
            section: section,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 找到 DraggableScrollableSheet
    final sheetFinder = find.byType(DraggableScrollableSheet);
    expect(sheetFinder, findsOneWidget);

    // 找到小白条 Handle 区域 (Top center handle container)
    final handleFinder = find.byType(GestureDetector).first;
    expect(handleFinder, findsWidgets);

    // 拖动小白条向下
    await tester.drag(handleFinder, const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(sheetFinder, findsOneWidget);
  });
}
