import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/market_screen.dart';

Map<String, dynamic> _marketPost({
  required int id,
  required String type,
}) {
  return {
    'id': id,
    'title': type == 'buy' ? '求购自行车' : '出售自行车',
    'content': '成色很好',
    'board_id': 2,
    'author_id': 1,
    'post_type': type,
    'price': 99,
    'created_at': '2026-08-20T08:00:00Z',
  };
}

Widget _buildMarket(Dio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(dio, loadStoredAuth: false),
      ),
      ChangeNotifierProvider(create: (_) => PostProvider(dio, enableCache: false)),
      ChangeNotifierProvider(create: (_) => ThemeProvider(loadOnStart: false)),
    ],
    child: const MaterialApp(home: MarketScreen()),
  );
}

void main() {
  testWidgets('搜索中切换类型后清除搜索会显示对应普通 feed', (tester) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final query = options.queryParameters['q']?.toString();
          final type = options.queryParameters['type']?.toString();
          final postType = type == 'buy' || query != null ? 'buy' : 'sell';
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'posts': [_marketPost(id: postType == 'buy' ? 2 : 1, type: postType)],
                'total': 1,
                'session_id': null,
              },
            ),
          );
        },
      ),
    );

    await tester.pumpWidget(_buildMarket(dio));
    await tester.pumpAndSettle();

    final search = find.byType(TextField);
    await tester.enterText(search, '自行车');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    await tester.tap(find.text('求购').first);
    await tester.pumpAndSettle();
    expect(find.text('求购自行车'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('求购自行车'), findsOneWidget);
    expect(find.text('还没有求购'), findsNothing);
  });
}
