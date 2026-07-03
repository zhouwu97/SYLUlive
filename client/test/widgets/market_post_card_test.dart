import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  @override
  User? get user => null;
}

void main() {
  testWidgets('商品卡片展示发布时选择的交易选项', (tester) async {
    final post = Post(
      id: 1,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      marketTags: const ['自提', '可小刀'],
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _FakeAuthProvider(),
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: MarketPostCard(post: post),
          ),
        ),
      ),
    );

    expect(find.text('自提'), findsOneWidget);
    expect(find.text('可小刀'), findsOneWidget);
  });
}
