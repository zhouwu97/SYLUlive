import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  @override
  User? get user => null;
}

void main() {
  testWidgets('网格封面贴合毛玻璃卡片边缘，关闭时恢复普通描边', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    var taps = 0;
    final post = Post(
        id: 1,
        title: '测试商品',
        content: '',
        boardId: 2,
        authorId: 1,
        postType: 'sell',
        price: 99,
        createdAt: DateTime(2026));
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider<AuthProvider>(
              create: (_) => _FakeAuthProvider()),
        ],
        child: MaterialApp(
            home: Scaffold(
                body: SizedBox(
                    width: 200,
                    child: MarketPostCard(
                        post: post, compact: true, onTap: () => taps++))))));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(AppCardSurface));
    final cover = tester.getRect(find.byType(AspectRatio));
    expect(cover.topLeft, card.topLeft);
    expect(cover.width, card.width);
    await tester.tap(find.text('测试商品'));
    expect(taps, 1);
    await theme.setFrostedGlass(false);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(AspectRatio)),
        card.topLeft + const Offset(1, 1));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

    expect(find.textContaining('自提'), findsOneWidget);
    expect(find.textContaining('可小刀'), findsOneWidget);
  });
}
