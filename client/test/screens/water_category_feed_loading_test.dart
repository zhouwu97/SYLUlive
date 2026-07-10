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
  testWidgets('空版块不等待权限和配置请求即可显示空态', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1179, 2556);
    addTearDown(tester.view.reset);

    final metadataGate = Completer<void>();
    addTearDown(() {
      if (!metadataGate.isCompleted) metadataGate.complete();
    });

    final metadataDio = Dio();
    metadataDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await metadataGate.future;
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );

    var postRequestCount = 0;
    final postDio = Dio();
    postDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          postRequestCount++;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'posts': <Map<String, dynamic>>[],
                'total': 0,
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
          ChangeNotifierProvider.value(
            value: WaterSectionProvider(metadataDio),
          ),
          ChangeNotifierProvider.value(
            value: WaterModeratorProvider(metadataDio),
          ),
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

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(postRequestCount, 1);
    expect(find.text('还没有竞赛内容'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
